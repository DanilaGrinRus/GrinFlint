import UIKit
import UniformTypeIdentifiers

/// Буфер обмена с ограничениями для чувствительных данных.
///
/// iOS не гарантирует удаление копий из системных журналов/буфера: `localOnly`
/// и `expirationDate` лишь уменьшают область и время жизни. Пользователю
/// нельзя обещать «полное удаление» — только «копия не уходит в Universal
/// Clipboard и живёт ограниченное время».
enum Clipboard {
    /// Копирует текст только в локальный буфер с коротким сроком жизни.
    static func copyLocalOnly(_ value: String, seconds: TimeInterval = 60) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(seconds),
            ]
        )
    }
}
