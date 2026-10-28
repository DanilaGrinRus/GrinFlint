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
    /// Боевой сервис. Параметр `service` у методов нужен для юнит-тестов,
    /// чтобы не трогать настоящий элемент кошелька.
    static let defaultService = "com.grinflint.wallet"
    /// Старая запись (без ACL) — только как источник для миграции.
    static let legacyAccount = "wallet-password"
    /// Новая запись с userPresence.
    static let protectedAccount = "wallet-password-v2"

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

    /// Что делать с найденными записями (чистая логика — покрыта юнит-тестами).
    enum MigrationPlan: Equatable {
        /// Уже есть защищённая запись — используем её.
        case useProtected
        /// Есть только старая запись, а защита возможна — переносим.
        case migrate
        /// Есть только старая запись, а защищать нечем — оставляем как есть.
        case keepLegacy
        /// Записей нет — создаём новый пароль.
        case createNew
    }

    static func plan(hasProtected: Bool, hasLegacy: Bool, canProtect: Bool) -> MigrationPlan {
        if hasProtected { return .useProtected }
        guard hasLegacy else { return .createNew }
        return canProtect ? .migrate : .keepLegacy
    }

    struct KeychainError: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let code = "OSStatus \(status)"
            switch status {
            case errSecMissingEntitlement:
                return "\(operation): Keychain недоступен (\(code)) — приложение запущено без подписи. Запустите сборку с подписью; данные кошелька не повреждены."
            case errSecUserCanceled:
                return "\(operation): подтверждение отменено. Повторите вход — кошелёк остаётся заблокированным."
            case errSecAuthFailed:
                return "\(operation): не удалось подтвердить личность (\(code)). Проверьте Face ID/код и повторите."
            case errSecInteractionNotAllowed:
                return "\(operation): Keychain недоступен, пока устройство заблокировано (\(code)). Разблокируйте телефон и повторите."
            case errSecItemNotFound:
                return "\(operation): запись не найдена (\(code)). Если кошелёк создавался ранее, восстановите его из seed-фразы — данные в хранилище не удалялись приложением."
            default:
                return "\(operation): ошибка Keychain (\(code)). Перезапустите приложение; если ошибка повторяется — сообщите код \(status). Кошелёк и seed-файл не изменялись."
            }
        }
    }

    // MARK: - Публичное API

    /// Возвращает сохранённый пароль или создаёт новый, только если записи нет.
    /// Ошибки чтения/миграции не приводят к созданию нового пароля —
    /// иначе существующий кошелёк стал бы нечитаемым.
    static func loadOrCreatePassword(service: String = defaultService) throws -> String {
        if let existing = try loadPassword(service: service) {
            return existing
        }
        let password = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
        try saveProtected(password, service: service)
        lastProtection = protectionAvailable ? .protected : .legacyNoAuth
        return password
    }

    /// Читает пароль: сначала новая запись, затем старая (с миграцией).
    static func loadPassword(service: String = defaultService) throws -> String? {
        let protected = try read(account: protectedAccount, service: service)
        let legacy = try read(account: legacyAccount, service: service)

        switch plan(
            hasProtected: protected != nil,
            hasLegacy: legacy != nil,
            canProtect: protectionAvailable
        ) {
        case .useProtected:
            lastProtection = .protected
            return protected
        case .migrate:
            guard let legacy else { return nil }
            return try migrateLegacy(legacy, service: service)
        case .keepLegacy:
            lastProtection = .legacyNoAuth
            return legacy
        case .createNew:
            lastProtection = .unavailable
            return nil
        }
    }

    // MARK: - Миграция

    private static func migrateLegacy(_ legacy: String, service: String) throws -> String {
        do {
            try saveProtected(legacy, service: service)
            // Контрольное чтение: только после него удаляем единственную запись.
            guard let check = try read(account: protectedAccount, service: service),
                  check == legacy else {
                try? delete(account: protectedAccount, service: service)
                lastProtection = .migrationPostponed
                return legacy
            }
            try? delete(account: legacyAccount, service: service)
            lastProtection = .legacyMigrated
            return legacy
        } catch let error as KeychainError where error.status == errSecUserCanceled {
            // Пользователь отменил подтверждение: не трогаем старую запись,
            // убираем недописанную новую и продолжаем со старым паролем.
            try? delete(account: protectedAccount, service: service)
            lastProtection = .migrationPostponed
            return legacy
        }
    }

    /// Доступна ли защита присутствием пользователя (биометрия или код).
    /// В симуляторе ACL не работает — значение по умолчанию `false`;
    /// юнит-тесты могут включить его, чтобы проверить саму миграцию.
    private(set) static var protectionAvailable: Bool = defaultProtectionAvailable()

    private static func defaultProtectionAvailable() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        #endif
    }

    // MARK: - Низкоуровневые операции

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Читает запись. Если элемент защищён, iOS запросит Face ID/код;
    /// после успешного подтверждения в этой сессии повторный запрос не нужен.
    private static func read(account: String, service: String) throws -> String? {
        var query = baseQuery(account: account, service: service)
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
    private static func saveProtected(_ password: String, service: String) throws {
        var query = baseQuery(account: protectedAccount, service: service)
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
                baseQuery(account: protectedAccount, service: service) as CFDictionary,
                update as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError(operation: "Обновление защищённого пароля", status: updateStatus)
            }
        default:
            throw KeychainError(operation: "Сохранение защищённого пароля", status: status)
        }
    }

    private static func saveLegacy(_ password: String, service: String) throws {
        var query = baseQuery(account: legacyAccount, service: service)
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(operation: "Сохранение старого пароля", status: status)
        }
    }

    private static func delete(account: String, service: String) throws {
        let status = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError(operation: "Удаление пароля (\(account))", status: status)
    }

    /// Защита запросом присутствия пользователя. nil — код/биометрия не заданы
    /// (или это симулятор, где ACL не применяется).
    private static func userPresenceAccessControl() -> SecAccessControl? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard protectionAvailable else { return nil }
        var error: Unmanaged<CFError>?
        return SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        )
        #endif
    }

    // MARK: - Помощники для юнит-тестов (только симулятор)

    #if targetEnvironment(simulator)
    /// Подменить доступность защиты, чтобы проверить миграцию в симуляторе.
    static func testSetProtectionAvailable(_ value: Bool) {
        protectionAvailable = value
    }

    static func testResetProtectionAvailable() {
        protectionAvailable = defaultProtectionAvailable()
    }

    static func testSaveLegacy(_ password: String, service: String) throws {
        try saveLegacy(password, service: service)
    }

    static func testDeleteAll(service: String) {
        try? delete(account: legacyAccount, service: service)
        try? delete(account: protectedAccount, service: service)
    }

    static func testHasProtectedRecord(service: String) -> Bool {
        guard let value = try? read(account: protectedAccount, service: service) else { return false }
        return value != nil
    }

    static func testHasLegacyRecord(service: String) -> Bool {
        guard let value = try? read(account: legacyAccount, service: service) else { return false }
        return value != nil
    }
    #endif
}
