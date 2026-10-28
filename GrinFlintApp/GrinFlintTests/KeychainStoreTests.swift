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
        XCTAssertEqual(KeychainStore.lastProtection, .legacyMigrated)
        // Перенос подтверждён чтением — старая запись удалена, новая на месте.
        XCTAssertTrue(KeychainStore.testHasProtectedRecord(service: service))
        XCTAssertFalse(KeychainStore.testHasLegacyRecord(service: service))
    }

    func testProtectedRecordWinsOverLegacy() throws {
        let protectedPassword = try KeychainStore.loadOrCreatePassword(service: service)
        try KeychainStore.testSaveLegacy("legacy-password", service: service)

        let loaded = try KeychainStore.loadPassword(service: service)
        XCTAssertEqual(loaded, protectedPassword)
        XCTAssertEqual(KeychainStore.lastProtection, .protected)
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
