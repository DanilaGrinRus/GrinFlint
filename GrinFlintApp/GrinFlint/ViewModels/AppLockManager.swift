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
    /// Поколение блокировки: растёт на каждой новой блокировке (фон, таймер,
    /// ручная). Результат начатой ранее аутентификации не снимает более
    /// новую блокировку.
    private var lockGeneration = 0

    init() {
        // При защищённом входе стартуем заблокированными.
        isLocked = WalletLock.isProtectionEnabled
    }

    // MARK: Жизненный цикл сцены

    func sceneDidBecomeActive() {
        isSceneActive = true
        restartTimer()
    }

    /// Экран ушёл в неактивное состояние (системный диалог, переключатель):
    /// закрываем содержимое, но не считаем это новой блокировкой — иначе
    /// системный запрос Face ID во время разблокировки сам себе мешал бы.
    func sceneWillResignActive() {
        isSceneActive = false
        stopTimer()
        if WalletLock.isProtectionEnabled { isLocked = true }
    }

    /// Приложение ушло в фон — это новая блокировка. Неуспевший вернуться
    /// результат аутентификации не должен её снять.
    func sceneDidEnterBackground() {
        isSceneActive = false
        stopTimer()
        lockGeneration &+= 1
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
        let generation = lockGeneration
        defer { isAuthenticating = false }

        do {
            // Пароль из Keychain мог потребовать подтверждения секунду назад
            // (политика userPresence): не показываем второй диалог подряд.
            if !BiometricAuth.recentlyConfirmed(within: 10) {
                try await BiometricAuth.require(reason: "Разблокируйте кошелёк")
            }
            // Пока шла аутентификация, приложение могло уйти в фон — это
            // более новая блокировка, прежний результат её не снимает.
            guard generation == lockGeneration else {
                isLocked = true
                stopTimer()
                return
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
        lockGeneration &+= 1
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
                guard let self else { return }
                self.lockGeneration &+= 1
                self.isLocked = true
                self.stopTimer()
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
