import Foundation
import LocalAuthentication

/// Биометрическая защита: Face ID / Touch ID с резервным кодом устройства.
///
/// Политика — `.deviceOwnerAuthentication` (биометрия, при отказе/отсутствии
/// датчика — код устройства). Любой отказ, отмена или ошибка означают, что
/// пользователь **не подтвердил** действие: вызывающий код обязан остаться
/// заблокированным и не выполнять защищённую операцию.
///
/// Исключение только для UI-тестов в симуляторе и только по явному аргументу
/// запуска `-simBiometric allow|deny|cancel`; на устройстве этот код не
/// компилируется.
enum BiometricAuth {
    enum BiometricError: LocalizedError {
        case cancelled
        case unavailable(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Подтверждение отменено — действие не выполнено."
            case .unavailable(let reason):
                return reason
            case .failed(let reason):
                return "Не удалось подтвердить личность: \(reason)"
            }
        }
    }

    /// Тип доступной биометрии для заголовка кнопки/подсказки.
    static var displayName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .none: return "код устройства"
        @unknown default: return "биометрию"
        }
    }

    /// Есть ли на устройстве биометрия или код-пароль (то, чем можно
    /// подтвердить действие). Без этого защита включена, но вход невозможен —
    /// это нужно показывать пользователю, а не молча пропускать.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Контекст последнего успешного подтверждения. Нужен, чтобы Keychain
    /// прочитал защищённый пароль без второго системного запроса в той же
    /// сессии (иначе пользователь видит два диалога подряд).
    private(set) static var authenticatedContext: LAContext?
    private(set) static var lastSuccessAt: Date?

    /// Было ли подтверждение пользователя совсем недавно (например, тем же
    /// запуском для чтения пароля из Keychain).
    static func recentlyConfirmed(within seconds: TimeInterval) -> Bool {
        guard let at = lastSuccessAt else { return false }
        return Date().timeIntervalSince(at) <= seconds
    }

    /// Сбрасывает окно «недавнего подтверждения» и контекст Keychain.
    /// Вызывается при любой блокировке (ручной, фон, таймер): после неё
    /// старый результат не должен заменять новый Face ID/код устройства.
    static func invalidateRecentConfirmation() {
        lastSuccessAt = nil
        authenticatedContext = nil
    }

    /// Причина, по которой подтверждение недоступно (nil — доступно).
    static var unavailableReason: String? {
        guard !isAvailable else { return nil }
        return "На устройстве не задан код-пароль: подтвердить личность нельзя. Задайте код-пароль в настройках iOS — без него вход в кошелёк и подпись запрещены."
    }

    /// Требует подтверждение пользователя.
    /// - Parameter reason: строка в системном диалоге.
    /// - Throws: `.cancelled` при отмене/отказе, `.unavailable` если нет
    ///   код-пароля/биометрии, `.failed` при прочих ошибках.
    static func require(reason: String) async throws {
        if let override = simulatorOverride() {
            switch override {
            case .allow:
                return
            case .deny:
                throw BiometricError.cancelled
            case .cancel:
                throw BiometricError.cancelled
            }
        }

        let context = LAContext()
        context.localizedCancelTitle = "Отмена"
        context.localizedFallbackTitle = "Ввести код устройства"
        var nsError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &nsError) else {
            let reason = unavailableReason ?? nsError?.localizedDescription
                ?? "Подтверждение недоступно на этом устройстве."
            throw BiometricError.unavailable(reason)
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            guard success else { throw BiometricError.cancelled }
            authenticatedContext = context
            lastSuccessAt = Date()
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .userFallback, .systemCancel, .appCancel,
                 .authenticationFailed, .biometryLockout:
                throw BiometricError.cancelled
            case .biometryNotEnrolled, .biometryNotAvailable, .passcodeNotSet:
                throw BiometricError.unavailable(
                    unavailableReason ?? error.localizedDescription
                )
            default:
                throw BiometricError.failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Только для UI-тестов в симуляторе

    #if targetEnvironment(simulator)
    /// Тестовая установка «недавнего подтверждения» без системного диалога.
    static func testSetRecentConfirmation(at date: Date) {
        lastSuccessAt = date
        authenticatedContext = LAContext()
    }
    #endif

    private enum SimulatorOverride: String {
        case allow
        case deny
        case cancel
    }

    /// Переопределение работает только в симуляторе и только по явному
    /// аргументу `-simBiometric allow|deny|cancel`. На устройстве всегда nil.
    private static func simulatorOverride() -> SimulatorOverride? {
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-simBiometric"),
              args.count > index + 1 else { return nil }
        return SimulatorOverride(rawValue: args[index + 1])
        #else
        return nil
        #endif
    }
}
