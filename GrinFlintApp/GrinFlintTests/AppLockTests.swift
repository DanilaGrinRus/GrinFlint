import XCTest
@testable import GrinFlint

/// Блокировка не должна оставлять «недавнее подтверждение»: после ручного
/// lock/фона/неактивного экрана разблокировка обязана требовать новый Face ID
/// или код, а старый LAContext не должен читать Keychain без запроса.
final class AppLockTests: XCTestCase {
    private var previousProtection: Bool!
    private var previousInterval: Int!

    override func setUpWithError() throws {
        previousProtection = WalletLock.isProtectionEnabled
        previousInterval = WalletLock.defaults.integer(forKey: WalletLock.autoLockIntervalKey)
        WalletLock.isProtectionEnabled = true
        WalletLock.autoLockInterval = .oneMinute
        BiometricAuth.invalidateRecentConfirmation()
    }

    override func tearDownWithError() throws {
        BiometricAuth.invalidateRecentConfirmation()
        WalletLock.isProtectionEnabled = previousProtection
        if previousInterval == 0 {
            WalletLock.defaults.removeObject(forKey: WalletLock.autoLockIntervalKey)
        } else {
            WalletLock.defaults.set(previousInterval, forKey: WalletLock.autoLockIntervalKey)
        }
    }

    func testManualLockResetsRecentAuthentication() {
        BiometricAuth.testSetRecentConfirmation(at: Date())
        XCTAssertTrue(BiometricAuth.recentlyConfirmed(within: 10))

        let lock = AppLockManager()
        lock.lockNow()

        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(BiometricAuth.recentlyConfirmed(within: 10))
    }

    func testBackgroundResetsRecentAuthentication() {
        BiometricAuth.testSetRecentConfirmation(at: Date())

        let lock = AppLockManager()
        lock.sceneDidEnterBackground()

        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(BiometricAuth.recentlyConfirmed(within: 10))
    }

    func testInactiveScreenResetsRecentAuthentication() {
        BiometricAuth.testSetRecentConfirmation(at: Date())

        let lock = AppLockManager()
        lock.sceneDidBecomeActive()
        lock.sceneWillResignActive()

        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(BiometricAuth.recentlyConfirmed(within: 10))
    }
}
