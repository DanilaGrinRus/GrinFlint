#if GRINFFI
import Foundation

/// Реализация WalletService поверх реального grin-wallet через FFI.
///
/// Использование (фаза 2):
///   let service = try GrinWalletFFIService(
///       dataDir: documentsDir.appendingPathComponent("grin-wallet").path,
///       nodeURL: "https://grinnode.live:3413",
///       chain: .floonet
///   )
///   WalletViewModel(service: service)
///
/// ВНИМАНИЕ: пароль пока хранится в памяти актора (этап 3: Keychain + Face ID).
actor GrinWalletFFIService: WalletService {
    enum Chain: String {
        case mainnet
        case floonet
    }

    private let handle: GrinWalletHandle
    private let password: String
    /// Журнал незавершённых переводов: Slatepack в истории не хранится,
    /// поэтому этапы переживают обновление истории и перезапуск приложения.
    private let pending: PendingOperationsStore
    private(set) var slatepackAddress = ""

    /// Для экрана настроек: это не демо-заглушка.
    nonisolated var backendName: String { "grin-wallet 5.5.1 (FFI)" }
    nonisolated var isDemo: Bool { false }

    /// spendable / awaiting / locked (наногрин → Decimal GRIN при чтении)
    private(set) var balance = Balance.zero
    private(set) var transactions: [TransactionRecord] = []

    init(dataDir: String, nodeURL: String, chain: Chain, password: String) throws {
        self.password = password
        // Журнал операций лежит рядом с данными кошелька.
        self.pending = PendingOperationsStore(
            directory: URL(fileURLWithPath: dataDir, isDirectory: true)
        )
        self.handle = try GrinWalletHandle(dataDir: dataDir, nodeURL: nodeURL, chain: chain.rawValue)
    }

    /// Незавершённый перевод для экрана портфеля.
    var pendingOperation: PendingOperation? { pending.latest }

    func dismissPending(id: UUID) async {
        pending.remove(id: id)
    }

    /// Создать новый seed; возвращает мнемонику.
    @discardableResult
    func createWallet(mnemonicLength: Int = 24) async throws -> String {
        let result: GrinMnemonicResult = try GrinFFI.call({ h in
            grin_wallet_create_seed(h.raw, password, UInt32(mnemonicLength), nil)
        }, handle: handle, as: GrinMnemonicResult.self)
        return result.mnemonic
    }

    /// Восстановить из seed-фразы.
    func restore(mnemonic: String) async throws {
        let words = mnemonic.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard words.count == 12 || words.count == 24 else {
            throw WalletError.invalidMnemonic
        }
        let _: GrinMnemonicResult = try GrinFFI.call({ h in
            grin_wallet_create_seed(h.raw, password, UInt32(words.count), mnemonic)
        }, handle: handle, as: GrinMnemonicResult.self)
    }

    /// Открыть кошелек и закэшировать slatepack-адрес.
    func open() async throws {
        let result: GrinAddressResult = try GrinFFI.call({ h in
            grin_wallet_open(h.raw, password)
        }, handle: handle, as: GrinAddressResult.self)
        slatepackAddress = result.address
    }

    // MARK: WalletService

    func refresh() async throws {
        let b: GrinBalanceResult = try GrinFFI.call({ h in
            grin_wallet_balance(h.raw, 1)
        }, handle: handle, as: GrinBalanceResult.self)
        balance = Self.mapBalance(b)

        let t: GrinTxsResult = try GrinFFI.call({ h in
            grin_wallet_txs(h.raw)
        }, handle: handle, as: GrinTxsResult.self)
        transactions = t.txs.map(Self.mapTx)
    }

    func prepareSend(destination: String, amountText: String, feeTier: FeeTier) async throws -> SendProposal {
        // Один незавершённый перевод за раз: повторный вызов подписал бы
        // вторую транзакцию и задвоил операцию.
        if let awaiting = pending.awaitingSend {
            throw WalletError.pendingOperationExists(awaiting.stage.title)
        }
        // Сумму разбирает общий Rust-контракт: 9 знаков, без усечения и
        // переполнения. Ошибка возвращается, а не превращается в 0.
        let parsed: GrinAmountResult
        do {
            parsed = try GrinFFI.callStandalone(
                { grin_wallet_parse_amount(amountText) },
                as: GrinAmountResult.self
            )
        } catch {
            throw WalletError.invalidAmount
        }
        let nano = parsed.nano
        let amount = Self.grin(nano)
        let dest = destination.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty else { throw WalletError.invalidAddress }
        let result: GrinSendResult = try GrinFFI.call({ h in
            grin_wallet_send(h.raw, nano, dest)
        }, handle: handle, as: GrinSendResult.self)
        let operation = PendingOperation(
            id: UUID(),
            kind: .send,
            stage: .awaitingResponse,
            slatepack: result.slatepack,
            destination: dest,
            amount: "\(amount)",
            fee: "\(Self.grin(result.fee))",
            txID: result.slate_id,
            createdAt: Date(),
            lastError: nil
        )
        pending.upsert(operation)
        return SendProposal(
            amount: amount,
            fee: Self.grin(result.fee),
            slatepack: result.slatepack,
            txID: UUID(uuidString: result.slate_id) ?? UUID()
        )
    }

    func receive(slatepack: String) async throws -> TransactionRecord {
        let result: GrinReceiveResult = try GrinFFI.call({ h in
            grin_wallet_receive(h.raw, slatepack)
        }, handle: handle, as: GrinReceiveResult.self)
        // Ответный Slatepack сохраняем: его нужно вернуть отправителю даже
        // после перезапуска приложения и обновления истории.
        let operation = PendingOperation(
            id: UUID(),
            kind: .receive,
            stage: .responseReady,
            slatepack: result.slatepack,
            destination: nil,
            amount: nil,
            fee: nil,
            txID: nil,
            createdAt: Date(),
            lastError: nil
        )
        pending.upsert(operation)
        return TransactionRecord(
            id: UUID(), type: .received, status: .unconfirmed,
            amount: 0, fee: 0, message: "",
            slatepack: nil, counterpart: nil, createdAt: Date(),
            responseSlatepack: result.slatepack
        )
    }

    /// Финализировать полученный от контрагента slatepack-ответ и запостить в сеть.
    func finalize(slatepackResponse: String) async throws {
        try GrinFFI.callStatus({ h in
            grin_wallet_finalize(h.raw, slatepackResponse)
        }, handle: handle)
        // Подпись прошла: запись о незавершённой отправке больше не нужна.
        if let awaiting = pending.awaitingSend {
            pending.remove(id: awaiting.id)
        }
    }

    func cancel(slateID: String) async throws {
        try GrinFFI.callStatus({ h in
            grin_wallet_cancel(h.raw, slateID)
        }, handle: handle)
    }

    func exportSlatepack(txID: UUID) async -> String? {
        if let stored = pending.operation(txID: txID.uuidString) {
            return stored.slatepack
        }
        return pending.latest?.slatepack ?? transactions.first { $0.id == txID }?.slatepack
    }

    // MARK: маппинг

    private static func nano(_ grin: Decimal) -> UInt64 {
        UInt64(truncating: (grin * 1_000_000_000) as NSDecimalNumber)
    }

    private static func grin(_ nano: UInt64) -> Decimal {
        Decimal(nano) / 1_000_000_000
    }

    private static func mapBalance(_ b: GrinBalanceResult) -> Balance {
        Balance(
            spendable: grin(b.spendable),
            awaiting: grin(b.awaiting),
            locked: grin(b.locked)
        )
    }

    private static func mapTx(_ t: GrinTxItem) -> TransactionRecord {
        let lowered = t.type.lowercased()
        let type: TxType = lowered.contains("received") ? .received
            : (lowered.contains("coinbase") ? .coinbase : .sent)
        // Reorg/отмена: grin-wallet помечает такую транзакцию Reverted или
        // Cancelled — показываем отдельный статус, а не «не подтверждено».
        let reverted = lowered.contains("reverted") || lowered.contains("cancelled")
        let status: TxStatus = reverted ? .reverted : (t.confirmed ? .confirmed : .unconfirmed)
        let amount = type == .sent ? -grin(t.amount) : grin(t.amount)
        let formatter = ISO8601DateFormatter()
        return TransactionRecord(
            id: UUID(uuidString: t.slate_id ?? "") ?? UUID(),
            type: type,
            status: status,
            amount: amount,
            fee: grin(t.fee ?? 0),
            message: t.message ?? "",
            slatepack: nil,
            counterpart: nil,
            createdAt: t.creation_ts.flatMap { formatter.date(from: $0) } ?? Date()
        )
    }
}

#endif // GRINFFI
