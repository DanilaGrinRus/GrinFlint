import Foundation
import Observation

/// Управляет экраном блокировки: вход (Face ID / код устройства) и
/// автоблокировка по таймеру неактивности. Таймер сбрасывается по событию
/// касания (`sendActivity()`).
///
/// Инвариант безопасности: `isLocked` снимается **только** после успешного
/// `BiometricAuth.require`. Любая ошибка/отмена оставляет экран блокировки.
@Observable
final class AppLockManager {
    private(set) var isLocked = false
    private(set) var isAuthenticating = false
    /// Причина, по которой разблокировка не удалась (для экрана блокировки).
    private(set) var lastError: String?

    /// Сцена активна (не в фоне) — таймер крутится только тогда.
    private var isSceneActive = true
    private var inactivityTimer: Timer?

    init() {
        // При защищённом входе стартуем заблокированными.
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

    /// Разблокировать может только успешное подтверждение пользователя.
    /// Ошибка/отмена/недоступность аутентификации оставляют замок закрытым.
    @MainActor
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        lastError = nil
        defer { isAuthenticating = false }

        do {
            // Пароль из Keychain мог потребовать подтверждения секунду назад
            // (политика userPresence): не показываем второй диалог подряд.
            if !BiometricAuth.recentlyConfirmed(within: 10) {
                try await BiometricAuth.require(reason: "Разблокируйте кошелёк")
            }
            isLocked = false
            lastError = nil
            restartTimer()
        } catch {
            // Никакого «пропускаем при ошибке»: остаёмся заблокированными.
            isLocked = true
            lastError = error.localizedDescription
            stopTimer()
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
