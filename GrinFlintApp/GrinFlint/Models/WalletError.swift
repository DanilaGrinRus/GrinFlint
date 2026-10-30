import Foundation

/// Ошибки кошелька. Живут в приложении, а не в `GrinFlintCore`: тексты
/// используют локализацию iOS (`String(localized:)`), которой нет в
/// кроссплатформенном Foundation.
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
    /// Введённая seed-фраза не соответствует кошельку, который уже есть
    /// в приложении. Восстановление остановлено, данные не менялись.
    case seedMismatch
    /// Журнал операций повреждён/не записывается; новые переводы запрещены.
    case journalUnavailable(String)

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
        case .seedMismatch:
            return String(
                localized: "Введённая seed-фраза не соответствует кошельку, который уже есть в приложении. Восстановление остановлено; существующие данные не изменялись."
            )
        case .journalUnavailable(let details):
            return String(
                localized: "Журнал операций недоступен: \(details). Новые переводы заблокированы, чтобы не потерять незавершённую операцию."
            )
        }
    }
}
