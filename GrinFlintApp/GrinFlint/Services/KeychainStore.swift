import Foundation
import LocalAuthentication
import Security

/// Хранение секретов кошелька в iOS Keychain.
///
/// Пароль шифрования БД кошелька — 32 случайных байта. На устройстве с
/// зарегистрированной биометрией элемент защищён `SecAccessControl` с флагом
/// `.userPresence`: прочитать пароль можно только после Face ID/Touch ID
/// (или кода устройства).
///
/// `.biometryCurrentSet` сознательно не используется: при повторной
/// регистрации Face ID (сброс, новый отпечаток) элемент становится
/// нечитаемым, и пароль кошелька теряется безвозвратно вместе с доступом
/// к средствам. `.userPresence` сохраняет фолбэк на код устройства.
enum KeychainStore {
    private static let service = "com.grinflint.wallet"
    private static let passwordAccount = "wallet-password"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status) where status == errSecMissingEntitlement:
                return "Keychain недоступен: приложение запущено без подписи (code signing)."
            case .unexpectedStatus(let status) where status == errSecUserCanceled:
                return "Разблокировка отменена — перезапустите приложение и подтвердите вход."
            default:
                return "Keychain ошибка \(self) — пересоздайте кошелёк или переустановите приложение."
            }
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Текст системного запроса, если элемент защищён биометрией.
        query[kSecUseOperationPrompt as String] = "Разблокируйте кошелёк"

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func savePassword(_ password: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecValueData as String: Data(password.utf8),
        ]
        if let access = biometryAccessControl() {
            query[kSecAttrAccessControl as String] = access
        } else {
            // Без биометрии: доступен после первой разблокировки устройства.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Защита элемента запросом присутствия пользователя (Face ID/Touch ID
    /// с фолбэком на код устройства). nil — биометрии нет или это симулятор.
    private static func biometryAccessControl() -> SecAccessControl? {
        #if targetEnvironment(simulator)
        // В симуляторе Face ID нет; системный запрос сломал бы смоук в CI.
        return nil
        #else
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return nil
        }
        return SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        )
        #endif
    }
}
