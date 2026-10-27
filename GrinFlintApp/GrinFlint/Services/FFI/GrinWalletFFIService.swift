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
    private(set) var slatepackAddress = ""

    /// spendable / awaiting / locked (наногрин → Decimal GRIN при чтении)
    private(set) var balance = Balance.zero
    private(set) var transactions: [TransactionRecord] = []

    init(dataDir: String, nodeURL: String, chain: Chain, password: String) throws {
        self.password = password
        self.handle = try GrinWalletHandle(dataDir: dataDir, nodeURL: nodeURL, chain: chain.rawValue)
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

    func prepareSend(destination: String, amount: Decimal, message: String, feeTier: FeeTier) async throws -> SendProposal {
        let nano = Self.nano(amount)
        let dest = destination.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty else { throw WalletError.invalidAddress }
        let result: GrinSendResult = try GrinFFI.call({ h in
            grin_wallet_send(h.raw, nano, dest, message)
        }, handle: handle, as: GrinSendResult.self)
        return SendProposal(
            amount: amount,
            fee: Self.grin(result.fee),
            message: message,
            slatepack: result.slatepack,
            txID: UUID(uuidString: result.slate_id) ?? UUID()
        )
    }

    func receive(slatepack: String, message: String) async throws -> TransactionRecord {
        let result: GrinReceiveResult = try GrinFFI.call({ h in
            grin_wallet_receive(h.raw, slatepack)
        }, handle: handle, as: GrinReceiveResult.self)
        // Ответный slatepack возвращается контрагенту вне этого метода;
        // транзакция появится в истории после refresh().
        return TransactionRecord(
            id: UUID(), type: .received, status: .unconfirmed,
            amount: 0, fee: 0, message: message,
            slatepack: result.slatepack, counterpart: nil, createdAt: Date()
        )
    }

    /// Финализировать полученный от контрагента slatepack-ответ и запостить в сеть.
    func finalize(slatepackResponse: String) async throws {
        try GrinFFI.callStatus({ h in
            grin_wallet_finalize(h.raw, slatepackResponse)
        }, handle: handle)
    }

    func cancel(slateID: String) async throws {
        try GrinFFI.callStatus({ h in
            grin_wallet_cancel(h.raw, slateID)
        }, handle: handle)
    }

    func exportSlatepack(txID: UUID) -> String? {
        transactions.first { $0.id == txID }?.slatepack
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
        let type: TxType = t.type.lowercased().contains("received") ? .received
            : (t.type.lowercased().contains("coinbase") ? .coinbase : .sent)
        let status: TxStatus = t.confirmed ? .confirmed : .unconfirmed
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
