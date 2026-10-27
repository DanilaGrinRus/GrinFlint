import Foundation
import Observation

/// Управляет экраном блокировки: вход (Face ID) и автоблокировка по таймеру
/// неактивности. Таймер сбрасывается по событию касания (`sendActivity()`).
@Observable
final class AppLockManager {
    private(set) var isLocked = false
    private(set) var isAuthenticating = false

    /// Сцена активна (не в фоне) — таймер крутится только тогда.
    private var isSceneActive = true
    private var inactivityTimer: Timer?

    init() {
        // При защищённом входе стартуем заблокированным.
        isLocked = WalletLock.isProtectionEnabled
    }

    // MARK: Жизненный цикл сцены

    func sceneDidBecomeActive() {
        isSceneActive = true
        restartTimer()
    }

    func sceneDidEnterBackground() {
        isSceneActive = false
        stopTimer()
        // Уход в фон считается неактивностью: блокируем немедленно.
        if WalletLock.isProtectionEnabled { isLocked = true }
    }

    // MARK: Активность

    /// Вызывается из onTapCapture при каждом взаимодействии с UI.
    func sendActivity() {
        restartTimer()
    }

    // MARK: Разблокировка

    @MainActor
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            try await BiometricAuth.require(reason: "Разблокируйте кошелёк")
            isLocked = false
            restartTimer()
        } catch BiometricAuth.BiometricError.cancelled {
            // Пользователь отменил — остаёмся на экране блокировки.
            isLocked = true
        } catch {
            isLocked = false
            restartTimer()
        }
    }

    /// Блокировка вручную (кнопка в настройках).
    func lockNow() {
        guard WalletLock.isProtectionEnabled else { return }
        isLocked = true
        stopTimer()
    }

    // MARK: Таймер

    private func restartTimer() {
        stopTimer()
        guard WalletLock.isProtectionEnabled, !isLocked, isSceneActive else { return }
        let interval = TimeInterval(WalletLock.autoLockInterval.rawValue)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isLocked = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        inactivityTimer = timer
    }

    private func stopTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }
}
