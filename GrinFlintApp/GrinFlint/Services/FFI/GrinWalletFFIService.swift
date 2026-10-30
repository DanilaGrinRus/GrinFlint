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
/// Пароль шифрования БД приходит из Keychain (см. WalletFactory);
/// в памяти актора он живёт только на время сессии.
actor GrinWalletFFIService: WalletService {
    enum Chain: String {
        case mainnet
        case floonet
    }

    private let handle: GrinWalletHandle
    private let password: String
    private let chain: Chain
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
    /// Последний refresh обновил состояние из ноды (update_wallet_state).
    private(set) var balanceIsFresh = false

    init(
        dataDir: String,
        nodeURL: String,
        chain: Chain,
        password: String,
        apiSecret: String? = nil
    ) throws {
        self.password = password
        self.chain = chain
        // Журнал операций лежит рядом с данными кошелька.
        self.pending = PendingOperationsStore(
            directory: URL(fileURLWithPath: dataDir, isDirectory: true)
        )
        self.handle = try GrinWalletHandle(
            dataDir: dataDir,
            nodeURL: nodeURL,
            chain: chain.rawValue,
            apiSecret: apiSecret ?? ""
        )
    }

    /// Незавершённый перевод для экрана портфеля.
    var pendingOperation: PendingOperation? { pending.active }

    /// Предупреждение о журнале операций (повреждён/не записывается).
    var journalWarning: String? { pending.errorDescription }

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

    /// Восстановить из seed-фразы. При заданной высоте скан начинается с неё,
    /// иначе — с генезиса (медленно на большой сети).
    func restore(mnemonic: String, restoreHeight: UInt64?) async throws {
        let words = mnemonic.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard words.count == 12 || words.count == 24 else {
            throw WalletError.invalidMnemonic
        }
        let height = restoreHeight ?? 0
        let _: GrinMnemonicResult = try GrinFFI.call({ h in
            grin_wallet_create_seed_at(h.raw, password, UInt32(words.count), mnemonic, height)
        }, handle: handle, as: GrinMnemonicResult.self)
    }

    /// Открыть кошелек и закэшировать slatepack-адрес.
    func open() async throws {
        let result: GrinAddressResult = try GrinFFI.call({ h in
            grin_wallet_open(h.raw, password)
        }, handle: handle, as: GrinAddressResult.self)
        slatepackAddress = result.address
        // После сбоя журнал мог разойтись с backend: сверяем стадии.
        reconcileJournal()
    }

    /// Адрес, который соответствует seed-фразе. Считается на временном
    /// кошельке в отдельном каталоге и удаляется: данные приложения не
    /// затрагиваются, нода не нужна (скан не запускается).
    func address(forMnemonic mnemonic: String) async throws -> String {
        let words = mnemonic.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard words.count == 12 || words.count == 24 else {
            throw WalletError.invalidMnemonic
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grinflint-seed-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let temp = try GrinWalletHandle(
            dataDir: directory.path,
            nodeURL: "http://127.0.0.1:1",
            chain: chain.rawValue
        )        let _: GrinMnemonicResult = try GrinFFI.call({ h in
            grin_wallet_create_seed_at(h.raw, password, UInt32(words.count), mnemonic, 0)
        }, handle: temp, as: GrinMnemonicResult.self)
        let opened: GrinAddressResult = try GrinFFI.call({ h in
            grin_wallet_open(h.raw, password)
        }, handle: temp, as: GrinAddressResult.self)
        return opened.address
    }

    // MARK: WalletService

    func refresh() async throws {
        let b: GrinBalanceResult = try GrinFFI.call({ h in
            grin_wallet_balance(h.raw, 1)
        }, handle: handle, as: GrinBalanceResult.self)
        balance = Self.mapBalance(b)
        balanceIsFresh = b.fresh

        let t: GrinTxsResult = try GrinFFI.call({ h in
            grin_wallet_txs(h.raw)
        }, handle: handle, as: GrinTxsResult.self)
        transactions = t.txs.map(Self.mapTx)
        reconcilePending()
        reconcileJournal()
    }

    /// Реальная комиссия backend до подписания (estimate_only).
    func estimateFee(destination: String, amountText: String) async throws -> FeeQuote {
        let nano = try Self.parseNano(amountText)
        let dest = try resolvedDestination(destination)
        let estimate: GrinFeeEstimate = try GrinFFI.call({ h in
            grin_wallet_estimate_fee(h.raw, nano, dest)
        }, handle: handle, as: GrinFeeEstimate.self)
        return FeeQuote(
            amount: Self.grin(nano),
            fee: Self.grin(estimate.fee),
            total: Self.grin(estimate.total)
        )
    }

    /// Максимум к отправке: spendable минус комиссия выбранных входов.
    /// Комиссия берётся из оценки backend (не выдуманный тариф).
    func maxSendable(destination: String) async throws -> MaxSendable {
        let dest = try resolvedDestination(destination)
        let b: GrinBalanceResult = try GrinFFI.call({ h in
            grin_wallet_balance(h.raw, 0)
        }, handle: handle, as: GrinBalanceResult.self)
        let spendable = b.spendable
        guard spendable > 1 else {
            throw WalletError.insufficientFunds(needed: 1, available: Self.grin(spendable))
        }
        // Оценка для максимальной суммы: при выборе всех входов комиссия та же,
        // что и для суммы на 1 наногрин меньше баланса.
        var maxNano = spendable - 1
        var fee: UInt64 = 0
        for _ in 0..<3 {
            let estimate: GrinFeeEstimate = try GrinFFI.call({ h in
                grin_wallet_estimate_fee(h.raw, maxNano, dest)
            }, handle: handle, as: GrinFeeEstimate.self)
            fee = estimate.fee
            guard fee > 0, fee < spendable else {
                throw WalletError.operationState("комиссия не укладывается в баланс")
            }
            let candidate = spendable - fee
            if candidate == maxNano { break }
            maxNano = candidate
        }
        guard maxNano > 0, maxNano < spendable else {
            throw WalletError.insufficientFunds(needed: Self.grin(fee), available: Self.grin(spendable))
        }
        return MaxSendable(amount: Self.grin(maxNano), fee: Self.grin(fee))
    }

    func prepareSend(destination: String, amountText: String) async throws -> SendProposal {
        // Журнал повреждён или не записался: backend мог создать операцию,
        // которую мы не сможем продолжить. Новые переводы запрещены.
        if pending.blocksNewSend {
            throw WalletError.journalUnavailable(
                pending.errorDescription ?? "журнал операций недоступен"
            )
        }
        // Один незавершённый перевод за раз: повторный вызов подписал бы
        // вторую транзакцию и задвоил операцию.
        if let awaiting = pending.unfinishedSend {
            throw WalletError.pendingOperationExists(awaiting.stage.title)
        }
        // Сумму разбирает общий Rust-контракт: 9 знаков, без усечения и
        // переполнения. Ошибка возвращается, а не превращается в 0.
        let nano = try Self.parseNano(amountText)
        let amount = Self.grin(nano)
        let dest = destination.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty else { throw WalletError.invalidAddress }
        let result: GrinSendResult = try GrinFFI.call({ h in
            grin_wallet_send(h.raw, nano, dest)
        }, handle: handle, as: GrinSendResult.self)
        let operation = PendingOperation(
            id: UUID(),
            kind: .send,
            stage: .prepared,
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
            stage: .prepared,
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
    ///
    /// Стадия `finalized` фиксируется на диске ДО вызова FFI: если публикация
    /// не прошла, подписанная транзакция сохранена и доступна для repost
    /// без новой подписи.
    func finalize(slatepackResponse: String) async throws {
        guard var operation = pending.unfinishedSend else {
            // Нет записи в журнале — публикуем напрямую, без стадий.
            try GrinFFI.callStatus({ h in
                grin_wallet_finalize(h.raw, slatepackResponse)
            }, handle: handle)
            return
        }

        // Фаза 1: подписать и сохранить Slate на диск. Журнал получает
        // finalized ТОЛЬКО после успешного возврата этой функции: иначе при
        // сбое UI предлагал бы repost несуществующей подписи.
        let prepared: GrinFinalizePrepared = try GrinFFI.call({ h in
            grin_wallet_finalize_prepare(h.raw, slatepackResponse)
        }, handle: handle, as: GrinFinalizePrepared.self)

        if let txID = operation.txID,
           txID.caseInsensitiveCompare(prepared.slate_id) != .orderedSame {
            throw WalletError.operationState("ответ относится к другому переводу")
        }
        operation.stage = .finalized
        operation.lastError = nil
        if operation.txID == nil { operation.txID = prepared.slate_id }
        pending.upsert(operation)

        // Фаза 2: публикация сохранённого Slate. Ошибка оставляет finalized,
        // чтобы UI предложил «Опубликовать снова».
        do {
            try GrinFFI.callStatus({ h in
                grin_wallet_repost(h.raw, prepared.slate_id)
            }, handle: handle)
        } catch {
            operation.lastError = error.localizedDescription
            pending.upsert(operation)
            throw error
        }

        operation.stage = .posted
        operation.lastError = nil
        pending.upsert(operation)
    }

    /// Отметить, что запрос передан получателю (prepared → requestSent).
    func markRequestSent(id: UUID) async {
        guard var operation = pending.operation(id: id), operation.stage == .prepared else { return }
        operation.stage = .requestSent
        pending.upsert(operation)
    }

    /// Отмена допустима только до финализации; после подписи — только repost.
    func cancel(operationID: UUID) async throws {
        guard var operation = pending.operation(id: operationID),
              operation.kind == .send,
              let slateID = operation.txID else {
            throw WalletError.operationState("операция не найдена")
        }
        guard operation.stage.acceptsResponse else {
            throw WalletError.operationState("отмена возможна только до финализации")
        }
        do {
            try GrinFFI.callStatus({ h in
                grin_wallet_cancel(h.raw, slateID)
            }, handle: handle)
        } catch {
            operation.lastError = error.localizedDescription
            pending.upsert(operation)
            throw error
        }
        operation.stage = .cancelled
        operation.lastError = nil
        pending.upsert(operation)
    }

    /// Повторная публикация уже подписанной транзакции (без новой подписи).
    func repost(operationID: UUID) async throws {
        guard var operation = pending.operation(id: operationID),
              operation.kind == .send,
              let slateID = operation.txID else {
            throw WalletError.operationState("операция не найдена")
        }
        guard operation.stage == .finalized else {
            throw WalletError.operationState("повтор публикации доступен только после подписи")
        }
        do {
            try GrinFFI.callStatus({ h in
                grin_wallet_repost(h.raw, slateID)
            }, handle: handle)
        } catch {
            operation.lastError = error.localizedDescription
            pending.upsert(operation)
            throw error
        }
        operation.stage = .posted
        operation.lastError = nil
        pending.upsert(operation)
    }

    func exportSlatepack(txID: UUID) async -> String? {
        if let stored = pending.operation(txID: txID.uuidString) {
            return stored.slatepack
        }
        return pending.latest?.slatepack ?? transactions.first { $0.id == txID }?.slatepack
    }

    // MARK: журнал и маппинг

    /// Сверка журнала с backend: подпись могла быть создана до записи стадии
    /// (и наоборот — стадия finalized без подписи после сбоя).
    private func reconcileJournal() {
        for var operation in pending.operations
        where operation.kind == .send && !operation.stage.isTerminal {
            guard let txID = operation.txID else { continue }
            guard let status: GrinTransferStatus = try? GrinFFI.call({ h in
                grin_wallet_transfer_status(h.raw, txID)
            }, handle: handle, as: GrinTransferStatus.self) else { continue }

            let snapshot = TransferStatusSnapshot(
                found: status.found,
                confirmed: status.confirmed ?? false,
                cancelled: status.cancelled ?? false,
                hasRepost: status.has_repost ?? false,
                slateState: status.slate_state
            )
            if let stage = JournalReconciler.stage(current: operation.stage, status: snapshot) {
                operation.stage = stage
                operation.lastError = nil
                pending.upsert(operation)
            }
        }
    }

    /// Подтверждение/отмена, замеченные в истории grin-wallet, двигают стадию.
    private func reconcilePending() {
        for var operation in pending.operations
        where operation.kind == .send && !operation.stage.isTerminal {
            guard let txID = operation.txID,
                  let tx = transactions.first(where: {
                      $0.id.uuidString.caseInsensitiveCompare(txID) == .orderedSame
                  }) else { continue }
            switch tx.status {
            case .confirmed:
                operation.stage = .confirmed
                operation.lastError = nil
                pending.upsert(operation)
            case .reverted:
                operation.stage = .cancelled
                operation.lastError = nil
                pending.upsert(operation)
            case .unconfirmed, .failed:
                break
            }
        }
    }

    /// Сумма из текста: точный разбор общим Rust-контрактом.
    private static func parseNano(_ amountText: String) throws -> UInt64 {
        do {
            let parsed: GrinAmountResult = try GrinFFI.callStandalone(
                { grin_wallet_parse_amount(amountText) },
                as: GrinAmountResult.self
            )
            return parsed.nano
        } catch {
            throw WalletError.invalidAmount
        }
    }

    /// Адрес получателя; пустой — свой адрес (для оценки комиссии до ввода).
    private func resolvedDestination(_ destination: String) throws -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard !slatepackAddress.isEmpty else { throw WalletError.invalidAddress }
        return slatepackAddress
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
