import Foundation

/// Сериализация/валидация Slatepack-сообщений Grin.
///
/// В реальном кошельке Slatepack шифруется по X25519 + AES-256-GCM и
/// формируется grin-wallet. Здесь — демо-кодек: структура та же самая
/// (bech32, HRP «grinslate»), но полезная нагрузка не зашифрована.
/// Замените `encodePayload`/`decodePayload` на вызовы grin-wallet через FFI.
enum SlatepackCodec {
    static let hrp = "grinslate"
    static let prefix = "grinslate1"

    struct Payload: Codable {
        var version: Int
        var sender: String
        var amount: DecimalString
        var message: String
        var nonce: Int
    }

    /// Decimal не кодируется напрямую в JSON — оборачиваем строкой.
    struct DecimalString: Codable {
        var value: String

        init(_ decimal: Decimal) {
            self.value = NSDecimalNumber(decimal: decimal).stringValue
        }

        var decimal: Decimal { Decimal(string: value) ?? 0 }
    }

    /// Проверяет, что строка похожа на Slatepack.
    static func isValid(_ slatepack: String) -> Bool {
        let trimmed = slatepack.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix(prefix)
    }

    /// Формирует демо-Slatepack из данных.
    static func encode(sender: String, amount: Decimal, message: String) -> String {
        let payload = Payload(
            version: 1,
            sender: sender,
            amount: DecimalString(amount),
            message: message,
            nonce: Int.random(in: 0..<Int.max)
        )
        guard let json = try? JSONEncoder().encode(payload) else { return prefix }
        let fiveBit = BitConverter.convertBits(Array(json), from: 8, to: 5)
        return Bech32.encode(hrp: hrp, data: fiveBit)
    }

    /// Извлекает сумму из демо-Slatepack (в продакшене — полный парсинг у grin-wallet).
    static func previewAmount(_ slatepack: String) -> Decimal? {
        // Демо: не раскодируем bech32, просто возвращаем nil —
        // UI покажет общий вид принятой транзакции.
        nil
    }
}
