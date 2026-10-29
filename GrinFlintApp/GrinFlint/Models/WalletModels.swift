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
    /// Транзакция откатилась (reorg) или отменена — средства возвращены.
    case reverted
    case failed

    var title: String {
        switch self {
        case .unconfirmed: return "Не подтверждено"
        case .confirmed: return "Подтверждено"
        case .reverted: return "Возвращено"
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

/// Реальная оценка комиссии от grin-wallet (`estimate_only`, без блокировки
/// средств). Комиссия считается по выбранным входам до подписания.
struct FeeQuote: Equatable {
    var amount: Decimal
    var fee: Decimal
    var total: Decimal
}

/// Максимум к отправке с учётом настоящей комиссии.
struct MaxSendable: Equatable {
    var amount: Decimal
    var fee: Decimal
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
    /// Ответный Slatepack входящей транзакции (FFI-режим): его нужно вернуть
    /// отправителю, чтобы тот завершил перевод. У исходящих и демо — nil.
    var responseSlatepack: String? = nil

    static func == (lhs: TransactionRecord, rhs: TransactionRecord) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.amount == rhs.amount
    }
}

/// Предложение на отправку, возвращаемое сервисом перед подписанием.
struct SendProposal {
    var amount: Decimal
    var fee: Decimal
    var slatepack: String
    var txID: UUID
}

enum WalletError: LocalizedError {
    case insufficientFunds(needed: Decimal, available: Decimal)
    case invalidAmount
    case invalidSlatepack
    case invalidAddress
    case invalidMnemonic
    case unavailable(String)
    case notImplemented(String)
    /// Есть незавершённый перевод: второй не создаём, чтобы не подписать
    /// повторно и не задвоить операцию.
    case pendingOperationExists(String)
    /// Действие недоступно на текущей стадии операции (например, отмена
    /// после финализации или повтор публикации до подписи).
    case operationState(String)

    var errorDescription: String? {
        switch self {
        case .insufficientFunds(let needed, let available):
            return String(
                localized: "Недостаточно средств: нужно \(GrinFormat.grin(needed)), доступно \(GrinFormat.grin(available))."
            )
        case .invalidAmount:
            return "Некорректная сумма."
        case .invalidSlatepack:
            return "Недействительный Slatepack: сообщение должно начинаться с «grinslate1…»."
        case .invalidAddress:
            return "Укажите Slatepack-адрес получателя (grin1…)."
        case .invalidMnemonic:
            return "Seed-фраза должна содержать 12 или 24 слова, разделённые пробелами."
        case .unavailable(let reason):
            return String(localized: "Кошелёк недоступен: \(reason)")
        case .notImplemented(let what):
            return String(localized: "Не реализовано в демо-режиме: \(what).")
        case .pendingOperationExists(let details):
            return String(
                localized: "Есть незавершённый перевод: \(details). Завершите его — повторная подпись не создаётся."
            )
        case .operationState(let details):
            return String(localized: "Действие недоступно: \(details).")
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

    /// Сумма без суффикса «GRIN» — для подстановки в поле ввода (до 9 знаков).
    static func amount(_ value: Decimal) -> String {
        let number = value as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 9
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
