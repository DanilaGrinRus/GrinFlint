import Foundation
import LocalAuthentication
import Security

/// Хранение пароля шифрования БД кошелька в iOS Keychain.
///
/// Политика доступа — `SecAccessControl` с флагом `.userPresence` (Face ID /
/// Touch ID, при отказе — код устройства), доступность
/// `WhenUnlockedThisDeviceOnly`. `.biometryCurrentSet` сознательно не
/// используется: после перерегистрации Face ID элемент становится нечитаемым,
/// и пароль кошелька теряется вместе с доступом к средствам.
///
/// Миграция: старые сборки писали пароль под `wallet-password` без ACL.
/// Такая запись читается один раз, переносится в `wallet-password-v2` с ACL,
/// проверяется чтением и только потом удаляется. Пока перенос не подтверждён,
/// старая запись остаётся на месте — единственный пароль кошелька не теряется.
enum KeychainStore {
    private static let service = "com.grinflint.wallet"
    /// Старая запись (без ACL) — только как источник для миграции.
    private static let legacyAccount = "wallet-password"
    /// Новая запись с userPresence.
    private static let protectedAccount = "wallet-password-v2"

    /// Диагностика последней операции (для экрана настроек/ошибок).
    enum Protection: String {
        case protected = "Keychain: пароль защищён Face ID / кодом устройства"
        case legacyMigrated = "Keychain: пароль перенесён под защиту Face ID"
        case legacyNoAuth = "Keychain: код-пароль не задан — защита присутствием недоступна"
        case migrationPostponed = "Keychain: перенос под защиту отложен — подтвердите вход"
        case simulator = "Keychain: симулятор — защита присутствием недоступна"
        case unavailable = "Keychain: пароль не найден"
    }

    private(set) static var lastProtection: Protection = .unavailable

    struct KeychainError: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let code = "OSStatus \(status)"
            switch status {
            case errSecMissingEntitlement:
                return "\(operation): Keychain недоступен (\(code)) — приложение запущено без подписи. "
                    + "Запустите сборку с подписью; данные кошелька не повреждены."
            case errSecUserCanceled:
                return "\(operation): подтверждение отменено. Повторите вход — кошелёк остаётся заблокированным."
            case errSecAuthFailed:
                return "\(operation): не удалось подтвердить личность (\(code)). Проверьте Face ID/код и повторите."
            case errSecInteractionNotAllowed:
                return "\(operation): Keychain недоступен, пока устройство заблокировано (\(code)). "
                    + "Разблокируйте телефон и повторите."
            case errSecItemNotFound:
                return "\(operation): запись не найдена (\(code)). Если кошелёк создавался ранее, "
                    + "восстановите его из seed-фразы — данные в хранилище не удалялись приложением."
            default:
                return "\(operation): ошибка Keychain (\(code)). Перезапустите приложение; "
                    + "если ошибка повторяется — сообщите код \(status). Кошелёк и seed-файл не изменялись."
            }
        }
    }

    // MARK: - Публичное API

    /// Возвращает сохранённый пароль или создаёт новый, только если записи нет.
    /// Ошибки чтения/миграции не приводят к созданию нового пароля —
    /// иначе существующий кошелёк стал бы нечитаемым.
    static func loadOrCreatePassword() throws -> String {
        if let existing = try loadPassword() {
            return existing
        }
        let password = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
        try saveProtected(password)
        lastProtection = .protected
        return password
    }

    /// Читает пароль: сначала новая запись, затем старая (с миграцией).
    static func loadPassword() throws -> String? {
        if let password = try read(account: protectedAccount) {
            lastProtection = .protected
            return password
        }
        if let legacy = try read(account: legacyAccount) {
            return try migrateLegacy(legacy)
        }
        lastProtection = .unavailable
        return nil
    }

    // MARK: - Миграция

    private static func migrateLegacy(_ legacy: String) throws -> String {
        #if targetEnvironment(simulator)
        // В симуляторе ACL/биометрия недоступны: перенос не выполняем и
        // явно сообщаем диагностикой (тестовое окружение, не прод-путь).
        lastProtection = .simulator
        return legacy
        #else
        guard protectionAvailable else {
            lastProtection = .legacyNoAuth
            return legacy
        }
        do {
            try saveProtected(legacy)
            // Контрольное чтение: только после него удаляем единственную запись.
            guard let check = try read(account: protectedAccount), check == legacy else {
                try? delete(account: protectedAccount)
                lastProtection = .migrationPostponed
                return legacy
            }
            try? delete(account: legacyAccount)
            lastProtection = .legacyMigrated
            return legacy
        } catch let error as KeychainError where error.status == errSecUserCanceled {
            // Пользователь отменил подтверждение: не трогаем старую запись,
            // убираем недописанную новую и продолжаем со старым паролем.
            try? delete(account: protectedAccount)
            lastProtection = .migrationPostponed
            return legacy
        }
        #endif
    }

    /// Доступна ли защита присутствием пользователя (биометрия или код).
    /// В симуляторе ACL не работает — там остаётся старая политика, и это
    /// ограничено только тестовым окружением.
    private static var protectionAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        #endif
    }

    // MARK: - Низкоуровневые операции

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Читает запись. Если элемент защищён, iOS запросит Face ID/код;
    /// после успешного подтверждения в этой сессии повторный запрос не нужен.
    private static func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context = BiometricAuth.authenticatedContext {
            query[kSecUseAuthenticationContext as String] = context
        } else {
            query[kSecUseOperationPrompt as String] = "Разблокируйте кошелёк"
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError(operation: "Чтение пароля (\(account))", status: status)
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Создаёт защищённую запись. Возвращает ошибку, если ACL недоступен.
    private static func saveProtected(_ password: String) throws {
        var query = baseQuery(account: protectedAccount)
        query[kSecValueData as String] = Data(password.utf8)

        if let access = userPresenceAccessControl() {
            query[kSecAttrAccessControl as String] = access
        } else {
            // Кода/биометрии нет: защита присутствием невозможна, но пароль
            // должен быть доступен кошельку. Это явно помечается диагностикой.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Уже существует (например, после отменённой миграции) — обновляем.
            let update: [String: Any] = [kSecValueData as String: Data(password.utf8)]
            let updateStatus = SecItemUpdate(
                baseQuery(account: protectedAccount) as CFDictionary,
                update as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError(operation: "Обновление защищённого пароля", status: updateStatus)
            }
        default:
            throw KeychainError(operation: "Сохранение защищённого пароля", status: status)
        }
    }

    private static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError(operation: "Удаление пароля (\(account))", status: status)
    }

    /// Защита запросом присутствия пользователя. nil — код/биометрия не заданы.
    private static func userPresenceAccessControl() -> SecAccessControl? {
        guard protectionAvailable else { return nil }
        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        )
        return access
    }
}
