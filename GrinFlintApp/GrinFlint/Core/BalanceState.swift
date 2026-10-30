import Foundation

/// Свежесть показанного баланса.
///
/// `unknown` — успешного ответа ноды ещё не было (нули нельзя считать
/// достоверными); `fresh` — последнее обновление от ноды прошло; `stale` —
/// показаны последние известные значения, но обновление не удалось.
enum BalanceFreshness: String, Codable, Equatable {
    case unknown
    case fresh
    case stale
}

/// Баланс вместе с происхождением данных. Чистая логика: используется
/// приложением и тестируется в SwiftPM-пакете под Windows/Linux.
struct BalanceState: Equatable {
    var balance: Balance
    var freshness: BalanceFreshness
    /// Время последнего успешного обновления от ноды.
    var lastUpdated: Date?
    /// Ошибка последнего обновления от ноды (nil — ошибки нет).
    var lastError: String?

    static let initial = BalanceState(
        balance: .zero,
        freshness: .unknown,
        lastUpdated: nil,
        lastError: nil
    )

    var isStale: Bool { freshness == .stale }
    var isUnknown: Bool { freshness == .unknown }

    /// Ответ ноды получен: значения достоверны.
    mutating func updateFromNode(_ balance: Balance, at date: Date = Date()) {
        self.balance = balance
        freshness = .fresh
        lastUpdated = date
        lastError = nil
    }

    /// Локальное изменение (создание/отмена перевода): значения обновляются,
    /// но свежесть от ноды не выдумывается.
    mutating func updateLocally(_ balance: Balance) {
        self.balance = balance
    }

    /// Обновление от ноды не удалось. Если данных ещё не было — остаёмся
    /// `unknown`; иначе прежние значения помечаются `stale`.
    mutating func fail(_ message: String) {
        freshness = lastUpdated == nil ? .unknown : .stale
        lastError = message
    }

    /// Подпись для экрана портфеля (без API локализации iOS).
    var freshnessText: String {
        switch freshness {
        case .unknown:
            return lastError == nil
                ? "Баланс ещё не получен"
                : "Баланс неизвестен — нет связи с нодой"
        case .fresh:
            guard let lastUpdated else { return "Обновлено" }
            return "Обновлено в \(Self.time.string(from: lastUpdated))"
        case .stale:
            let stamp = lastUpdated.map { Self.time.string(from: $0) } ?? "ранее"
            return "Нет связи с нодой — данные на \(stamp)"
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
