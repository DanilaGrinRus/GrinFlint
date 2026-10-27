import Foundation
import Security

/// Хранение секретов кошелька в iOS Keychain.
///
/// Этап 2 (минимум): генерируемый пароль шифрования БД кошелька.
/// Дальше (Фаза 2 роадмапа): seed backup, биометрия
/// (kSecAccessControlBiometryCurrentSet) на чтение пароля.
enum KeychainStore {
    private static let service = "com.grinflint.wallet"
    private static let passwordAccount = "wallet-password"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            "Keychain ошибка \(self) — пересоздайте кошелёк или переустановите приложение."
        }
    }

    /// Возвращает сохранённый пароль или создаёт и сохраняет новый.
    static func loadOrCreatePassword() throws -> String {
        if let existing = try loadPassword() {
            return existing
        }
        let password = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
        try savePassword(password)
        return password
    }

    static func loadPassword() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func savePassword(_ password: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecValueData as String: Data(password.utf8),
            // Доступен после первой разблокировки устройства;
            // для симулятора и CI (без entitlements) работает штатно.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }
}
