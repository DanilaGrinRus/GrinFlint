import Foundation

/// Форматирование сумм Grin (9 знаков — наногрин).
///
/// Чистая логика: файл компилируется и в iOS-приложении, и в SwiftPM-пакете
/// `GrinFlintCore` для тестов под Windows/Linux. Darwin-специфичных API здесь нет.
enum GrinFormat {
    static func grin(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 9
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let formatted = formatter.string(from: number) ?? "0"
        return "\(formatted) GRIN"
    }

    static func short(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: number) ?? "0"
    }

    /// Сумма без суффикса «GRIN» — для подстановки в поле ввода (до 9 знаков).
    static func amount(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
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
