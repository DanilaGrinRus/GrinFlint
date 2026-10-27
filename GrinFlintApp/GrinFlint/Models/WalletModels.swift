import Foundation

/// Тип транзакции.
enum TxType: String, Codable {
    case sent
    case received
    case coinbase
}

/// Статус подтверждения (Mimblewimble: подтверждение = появление в блоке).
enum TxStatus: String, Codable {
    case unconfirmed
    case confirmed
    case failed

    var title: String {
        switch self {
        case .unconfirmed: return "Не подтверждено"
        case .confirmed: return "Подтверждено"
        case .failed: return "Ошибка"
        }
    }
}

/// Остатки кошелька.
struct Balance: Equatable {
    /// Доступно к трате (зрелые выходы).
    var spendable: Decimal
    /// Неподтверждённые входящие.
    var awaiting: Decimal
    /// Заблокировано исходящими транзакциями.
    var locked: Decimal

    var total: Decimal { spendable + awaiting + locked }

    static let zero = Balance(spendable: 0, awaiting: 0, locked: 0)
}

/// Тариф комиссии (упрощённо: 1/2/3 как в grin-wallet).
enum FeeTier: Int, CaseIterable, Identifiable {
    case slow = 1
    case standard = 2
    case fast = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .slow: return "Медленно"
        case .standard: return "Стандарт"
        case .fast: return "Быстро"
        }
    }

    var fee: Decimal {
        switch self {
        case .slow: return Decimal(string: "0.001")!
        case .standard: return Decimal(string: "0.003")!
        case .fast: return Decimal(string: "0.008")!
        }
    }

    var eta: String {
        switch self {
        case .slow: return "~1 час"
        case .standard: return "~10 мин"
        case .fast: return "~1 мин"
        }
    }
}

/// Запись транзакции в истории.
struct TransactionRecord: Identifiable, Equatable {
    let id: UUID
    var type: TxType
    var status: TxStatus
    var amount: Decimal      // для sent — отрицательная сумма с учётом комиссии
    var fee: Decimal
    var message: String
    var slatepack: String?   // Slatepack, если транзакция ещё не передана контрагенту
    var counterpart: String? // адрес/примечание контрагента
    let createdAt: Date

    static func == (lhs: TransactionRecord, rhs: TransactionRecord) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.amount == rhs.amount
    }
}

/// Предложение на отправку, возвращаемое сервисом перед подписанием.
struct SendProposal {
    var amount: Decimal
    var fee: Decimal
    var message: String
    var slatepack: String
    var txID: UUID
}

enum WalletError: LocalizedError {
    case insufficientFunds(needed: Decimal, available: Decimal)
    case invalidAmount
    case invalidSlatepack
    case invalidAddress
    case invalidMnemonic
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .insufficientFunds(let needed, let available):
            return "Недостаточно средств: нужно \(GrinFormat.grin(needed)), доступно \(GrinFormat.grin(available))."
        case .invalidAmount:
            return "Некорректная сумма."
        case .invalidSlatepack:
            return "Недействительный Slatepack: сообщение должно начинаться с «grinslate1…»."
        case .invalidAddress:
            return "Укажите Slatepack-адрес получателя (grin1…)."
        case .invalidMnemonic:
            return "Seed-фраза должна содержать 12 или 24 слова, разделённые пробелами."
        case .notImplemented(let what):
            return "Не реализовано в демо-режиме: \(what)."
        }
    }
}

/// Форматирование сумм Grin (9 знаков — наногрин).
enum GrinFormat {
    static func grin(_ value: Decimal) -> String {
        let number = value as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 9
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let formatted = formatter.string(from: number) ?? "0"
        return "\(formatted) GRIN"
    }

    static func short(_ value: Decimal) -> String {
        let number = value as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: number) ?? "0"
    }

    /// Парсит строку вида "10.5" в Decimal (до 9 знаков).
    static func parse(_ string: String) -> Decimal? {
        let cleaned = string.replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: cleaned), value > 0 else { return nil }
        return value
    }
}

/// Дата/время транзакции.
enum TxDate {
    static func section(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = Locale(identifier: "ru_RU")
        return f.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        f.locale = Locale(identifier: "ru_RU")
        return f.string(from: date)
    }
}
