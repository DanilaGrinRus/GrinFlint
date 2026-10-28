import Foundation
import UserNotifications

/// Локальные напоминания о незавершённой интерактивной транзакции.
///
/// Grin-перевод завершается совместно: отправитель создаёт Slatepack, получатель
/// возвращает ответный, и только после этого средства уходят в сеть. Если
/// закрыть приложение между шагами, транзакция остаётся незавершённой —
/// напоминание возвращает пользователя к нужному экрану.
enum TxReminders {
    private static let prefix = "grinflint-pending-"

    /// Через сколько напомнить (по умолчанию 10 минут).
    static let defaultDelay: TimeInterval = 600

    /// Запросить разрешение и запланировать напоминание по транзакции.
    /// Разрешение спрашивается при первой отправке/приёме, а не на старте.
    static func schedule(id: String, after delay: TimeInterval = defaultDelay) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Транзакция не завершена"
            content.body = "Вернитесь в GrinFlint и передайте ответный Slatepack — иначе средства останутся заблокированными."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(60, delay),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: prefix + id,
                content: content,
                trigger: trigger
            )
            center.add(request)
        }
    }

    /// Снять все напоминания (транзакция завершена или отменена).
    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
