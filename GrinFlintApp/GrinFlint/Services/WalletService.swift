import Foundation

/// Абстракция кошелька Grin.
///
/// ПРОДАКШЕН-ИНТЕГРАЦИЯ:
/// официальный `grin-wallet` написан на Rust и подключается к iOS через
/// статическую библиотеку и FFI (C ABI). Типовой путь:
///   1. собрать grin-wallet как static lib для aarch64-apple-ios;
///   2. сгенерировать C-header (cbindgen) для wallet_init / wallet_recover /
///      tx_create / tx_finalize / slatepack_decrypt;
///   3. добавить .xcframework в проект, вызовы обернуть в `actor` типа
///      `GrinWalletFFIService`, реализующего этот протокол;
///   4. состояние (seed, выходы) хранить в зашифрованном контейнере
///      (Keychain + SQLCipher), как это делает Flint.
protocol WalletService: AnyObject {
    var balance: Balance { get async }
    var transactions: [TransactionRecord] { get async }
    var slatepackAddress: String { get async }

    /// Открыть существующий кошелёк (после создания/восстановления или при
    /// старте приложения). Реализация может закэшировать slatepack-адрес.
    func open() async throws

    /// Создать новый кошелёк и вернуть seed-фразу (24 слова).
    func createWallet(mnemonicLength: Int) async throws -> String

    /// Восстановить кошелёк из seed-фразы.
    func restore(mnemonic: String) async throws

    /// Обновить состояние с ноды. В демо: «добывается блок» и
    /// неподтверждённые транзакции становятся подтверждёнными.
    func refresh() async throws

    /// Создать транзакцию на отправку и получить Slatepack для контрагента.
    /// `destination` — Slatepack-адрес получателя (grin1…).
    func prepareSend(destination: String, amount: Decimal, feeTier: FeeTier) async throws -> SendProposal

    /// Принять Slatepack контрагента и зачислить средства.
    func receive(slatepack: String) async throws -> TransactionRecord

    /// Экспортировать транзакцию как Slatepack (пока не передали контрагенту).
    func exportSlatepack(txID: UUID) async -> String?

    /// Название блокчейн-бэкенда (для экрана настроек).
    var backendName: String { get }

    /// true — демо-реализация без сети (MockWalletService).
    var isDemo: Bool { get }

    /// Причина, по которой реальный сервис не поднялся (nil — всё в порядке).
    /// Нужен, чтобы показать экран ошибки вместо демо-баланса.
    var unavailableReason: String? { get }

    /// Завершить отправку: принять ответный Slatepack получателя и отправить
    /// финальную транзакцию в сеть. В демо — просто подтверждает запись.
    func finalize(slatepackResponse: String) async throws
}

extension WalletService {
    var backendName: String { "демо-режим (MockWalletService)" }
    var isDemo: Bool { true }
    var unavailableReason: String? { nil }
}

/// Заглушка, когда grin-wallet не поднялся: любая операция возвращает ошибку
/// с причиной. Раньше в этом случае молча включался демо-режим с фальшивым
/// балансом — для кошелька это недопустимо.
final class UnavailableWalletService: WalletService {
    let reason: String

    let balance = Balance.zero
    let transactions: [TransactionRecord] = []
    let slatepackAddress = ""

    nonisolated var backendName: String { "grin-wallet недоступен" }
    nonisolated var isDemo: Bool { false }
    var unavailableReason: String? { reason }

    init(reason: String) {
        self.reason = reason
    }

    private func bail() throws -> Never {
        throw WalletError.unavailable(reason)
    }

    func open() async throws { try bail() }

    func createWallet(mnemonicLength: Int) async throws -> String { try bail() }

    func restore(mnemonic: String) async throws { try bail() }

    func refresh() async throws { try bail() }

    func prepareSend(destination: String, amount: Decimal, feeTier: FeeTier) async throws -> SendProposal {
        try bail()
    }

    func receive(slatepack: String) async throws -> TransactionRecord { try bail() }

    func exportSlatepack(txID: UUID) async -> String? { nil }

    func finalize(slatepackResponse: String) async throws { try bail() }
}

/// Демо-реализация: всё состояние в памяти, транзакции не уходят в сеть.
final class MockWalletService: WalletService {
    private(set) var balance = Balance(
        spendable: Decimal(string: "148.352000000")!,
        awaiting: Decimal(string: "12.500000000")!,
        locked: 0
    )

    private(set) var transactions: [TransactionRecord]

    let slatepackAddress = "grin1q5kv3zyx7w8xjf0v2t4h9d6c3b1n5p7m9k2l4r6s8u0e2q4w6y8i0o2p4a6s8d"

    /// Слова для демо-генерации seed (не настоящая мнемоника Grin —
    /// настоящая появляется в GRINFFI-режиме из grin_wallet_create_seed).
    private static let demoWords = [
        "apple", "river", "stone", "cloud", "meadow", "bridge", "copper",
        "forest", "harbor", "ladder", "planet", "silver", "window", "grape",
        "anchor", "cactus", "ember", "frost", "market", "oak", "sunset",
        "velvet", "letter", "dream", "bonus", "wiggle"
    ]

    init() {
        let now = Date()
        transactions = [
            TransactionRecord(
                id: UUID(), type: .received, status: .confirmed,
                amount: Decimal(string: "12.5")!, fee: 0,
                message: "Спасибо за ужин 🍕",
                slatepack: nil, counterpart: "grin1q9d8c7b6a5z4x3v2n1m0l9k8j7h6g5f4d3s2a1p0o9i8u7y6t5r4e3w2q1",
                createdAt: now.addingTimeInterval(-3600 * 26)
            ),
            TransactionRecord(
                id: UUID(), type: .sent, status: .confirmed,
                amount: Decimal(string: "-5.2")!, fee: Decimal(string: "0.003")!,
                message: "Возврат долга",
                slatepack: nil, counterpart: "grin1qa1s2d3f4g5h6j7k8l9z0x1c2v3b4n5m6p7o8i9u0y1t2r3e4w5q6a7s8d9",
                createdAt: now.addingTimeInterval(-3600 * 50)
            ),
            TransactionRecord(
                id: UUID(), type: .coinbase, status: .confirmed,
                amount: Decimal(string: "60")!, fee: 0,
                message: "Mining reward",
                slatepack: nil, counterpart: nil,
                createdAt: now.addingTimeInterval(-3600 * 96)
            ),
        ]
    }

    func open() async throws {
        // Демо: нечего открывать.
    }

    func createWallet(mnemonicLength: Int) async throws -> String {
        try await Task.sleep(nanoseconds: 400_000_000)
        return (0..<max(mnemonicLength, 12)).map { _ in
            Self.demoWords.randomElement() ?? "word"
        }.joined(separator: " ")
    }

    func restore(mnemonic: String) async throws {
        let words = mnemonic.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard words.count == 12 || words.count == 24 else {
            throw WalletError.invalidMnemonic
        }
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    func refresh() async throws {
        // Симуляция нового блока: всё неподтверждённое подтверждается.
        try await Task.sleep(nanoseconds: 700_000_000)
        for index in transactions.indices where transactions[index].status == .unconfirmed {
            transactions[index].status = .confirmed
            if transactions[index].type == .received {
                balance.awaiting -= transactions[index].amount
                balance.spendable += transactions[index].amount
            } else if transactions[index].type == .sent {
                // Средства уже вычтены из spendable при создании —
                // при подтверждении просто разблокируем остаток.
                balance.locked -= (transactions[index].amount.magnitude + transactions[index].fee)
            }
        }
    }

    func prepareSend(destination: String, amount: Decimal, feeTier: FeeTier) async throws -> SendProposal {
        let fee = feeTier.fee
        let dest = destination.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty else { throw WalletError.invalidAddress }
        guard amount > 0 else { throw WalletError.invalidAmount }
        let needed = amount + fee
        guard balance.spendable >= needed else {
            throw WalletError.insufficientFunds(needed: needed, available: balance.spendable)
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        let txID = UUID()
        let slatepack = SlatepackCodec.encode(sender: slatepackAddress, amount: amount)
        // Блокируем средства и создаём неподтверждённую исходящую запись.
        balance.spendable -= needed
        balance.locked += needed
        transactions.insert(
            TransactionRecord(
                id: txID, type: .sent, status: .unconfirmed,
                amount: -amount, fee: fee, message: "",
                slatepack: slatepack, counterpart: dest, createdAt: Date()
            ),
            at: 0
        )
        return SendProposal(amount: amount, fee: fee, slatepack: slatepack, txID: txID)
    }

    func receive(slatepack: String) async throws -> TransactionRecord {
        guard SlatepackCodec.isValid(slatepack) else {
            throw WalletError.invalidSlatepack
        }
        try await Task.sleep(nanoseconds: 400_000_000)

        // Демо: принимаем фиксированную сумму (парсинг slate — у grin-wallet).
        let amount = Decimal(string: "3.141592653")!
        balance.awaiting += amount
        let record = TransactionRecord(
            id: UUID(), type: .received, status: .unconfirmed,
            amount: amount, fee: 0, message: "",
            slatepack: nil, counterpart: String(slatepack.prefix(24)) + "…",
            createdAt: Date()
        )
        transactions.insert(record, at: 0)
        return record
    }

    func exportSlatepack(txID: UUID) async -> String? {
        transactions.first { $0.id == txID }?.slatepack
    }

    func finalize(slatepackResponse: String) async throws {
        guard SlatepackCodec.isValid(slatepackResponse) else {
            throw WalletError.invalidSlatepack
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        guard let index = transactions.firstIndex(where: { $0.type == .sent && $0.status == .unconfirmed }) else {
            return
        }
        transactions[index].status = .confirmed
        balance.locked -= (transactions[index].amount.magnitude + transactions[index].fee)
        transactions[index].slatepack = nil
    }
}
