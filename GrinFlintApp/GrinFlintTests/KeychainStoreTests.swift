import XCTest
import Security
@testable import GrinFlint

/// Юнит-тесты KeychainStore: политика миграции, перенос старого пароля без
/// потери единственной рабочей записи и понятные тексты ошибок.
///
/// Используется отдельный service на каждый тест, чтобы не трогать элемент
/// настоящего кошелька. Биометрический ACL в симуляторе не применяется,
/// поэтому проверяется сама логика переноса (см. `testSetProtectionAvailable`).
final class KeychainStoreTests: XCTestCase {
    private var service: String!

    override func setUpWithError() throws {
        service = "com.grinflint.wallet.tests.\(UUID().uuidString)"
        KeychainStore.testResetProtectionAvailable()
    }

    override func tearDownWithError() throws {
        KeychainStore.testDeleteAll(service: service)
        KeychainStore.testResetProtectionAvailable()
    }

    // MARK: Политика

    func testPlanMatrix() {
        XCTAssertEqual(
            KeychainStore.plan(hasProtected: true, hasLegacy: true, canProtect: true),
            .useProtected
        )
        XCTAssertEqual(
            KeychainStore.plan(hasProtected: false, hasLegacy: true, canProtect: true),
            .migrate
        )
        XCTAssertEqual(
            KeychainStore.plan(hasProtected: false, hasLegacy: true, canProtect: false),
            .keepLegacy
        )
        XCTAssertEqual(
            KeychainStore.plan(hasProtected: false, hasLegacy: false, canProtect: true),
            .createNew
        )
    }

    // MARK: Пароль

    func testCreatesPasswordInEmptyStore() throws {
        let password = try KeychainStore.loadOrCreatePassword(service: service)
        XCTAssertFalse(password.isEmpty)
        XCTAssertTrue(KeychainStore.testHasProtectedRecord(service: service))
        XCTAssertFalse(KeychainStore.testHasLegacyRecord(service: service))
        // В симуляторе ACL не применяется: запись не должна выдаваться за защищённую.
        XCTAssertEqual(KeychainStore.testProtectionState(service: service), .noUserPresence)
        XCTAssertEqual(KeychainStore.lastProtection, .legacyNoAuth)
    }

    func testReusesExistingPassword() throws {
        let first = try KeychainStore.loadOrCreatePassword(service: service)
        let second = try KeychainStore.loadOrCreatePassword(service: service)
        XCTAssertEqual(first, second)
    }

    // MARK: Миграция

    func testLegacyKeptWhenProtectionUnavailable() throws {
        try KeychainStore.testSaveLegacy("legacy-password", service: service)
        KeychainStore.testSetProtectionAvailable(false)

        let loaded = try KeychainStore.loadPassword(service: service)
        XCTAssertEqual(loaded, "legacy-password")
        XCTAssertEqual(KeychainStore.lastProtection, .legacyNoAuth)
        // Старая запись остаётся единственной рабочей.
        XCTAssertTrue(KeychainStore.testHasLegacyRecord(service: service))
        XCTAssertFalse(KeychainStore.testHasProtectedRecord(service: service))
    }

    func testLegacyMigratedWhenProtectionAvailable() throws {
        try KeychainStore.testSaveLegacy("legacy-password", service: service)
        KeychainStore.testSetProtectionAvailable(true)

        let loaded = try KeychainStore.loadPassword(service: service)
        XCTAssertEqual(loaded, "legacy-password")
        // В симуляторе ACL создать нельзя: перенос данных есть, но защита
        // не подтверждена и не должна называться «защищён».
        XCTAssertEqual(KeychainStore.testProtectionState(service: service), .noUserPresence)
        XCTAssertEqual(KeychainStore.lastProtection, .simulator)
        // Перенос подтверждён чтением — старая запись удалена, новая на месте.
        XCTAssertTrue(KeychainStore.testHasProtectedRecord(service: service))
        XCTAssertFalse(KeychainStore.testHasLegacyRecord(service: service))
    }

    func testProtectedRecordWinsOverLegacy() throws {
        let protectedPassword = try KeychainStore.loadOrCreatePassword(service: service)
        try KeychainStore.testSaveLegacy("legacy-password", service: service)

        let loaded = try KeychainStore.loadPassword(service: service)
        XCTAssertEqual(loaded, protectedPassword)
        // Симулятор без ACL: не выдаём запись за защищённую только по имени.
        XCTAssertEqual(KeychainStore.lastProtection, .legacyNoAuth)
    }

    func testUnprotectedV2IsNotReportedAsProtected() throws {
        try KeychainStore.testSaveUnprotectedProtectedRecord("plain-password", service: service)
        KeychainStore.testSetProtectionAvailable(true)

        let loaded = try KeychainStore.loadPassword(service: service)
        XCTAssertEqual(loaded, "plain-password")
        XCTAssertEqual(KeychainStore.testProtectionState(service: service), .noUserPresence)
        XCTAssertEqual(KeychainStore.lastProtection, .simulator)
    }

    func testMissingProtectionState() {
        XCTAssertEqual(KeychainStore.testProtectionState(service: service), .missing)
    }

    func testNodeAPISecretRoundTripAndDelete() throws {
        XCTAssertNil(try KeychainStore.loadNodeAPISecret(service: service))

        try KeychainStore.saveNodeAPISecret("s3cret", service: service)
        XCTAssertEqual(try KeychainStore.loadNodeAPISecret(service: service), "s3cret")

        try KeychainStore.saveNodeAPISecret("new-secret", service: service)
        XCTAssertEqual(try KeychainStore.loadNodeAPISecret(service: service), "new-secret")

        try KeychainStore.saveNodeAPISecret("", service: service)
        XCTAssertNil(try KeychainStore.loadNodeAPISecret(service: service))
    }

    // MARK: Ошибки

    func testErrorDescriptionsAreActionable() {
        let unsigned = KeychainStore.KeychainError(
            operation: "Чтение пароля",
            status: errSecMissingEntitlement
        ).errorDescription ?? ""
        XCTAssertTrue(unsigned.contains("без подписи"), unsigned)
        XCTAssertFalse(unsigned.contains("пересоздайте"), unsigned)

        let cancelled = KeychainStore.KeychainError(
            operation: "Чтение пароля",
            status: errSecUserCanceled
        ).errorDescription ?? ""
        XCTAssertTrue(cancelled.contains("заблокированным"), cancelled)

        let notFound = KeychainStore.KeychainError(
            operation: "Чтение пароля",
            status: errSecItemNotFound
        ).errorDescription ?? ""
        XCTAssertTrue(notFound.contains("seed-фразы"), notFound)
    }
}
