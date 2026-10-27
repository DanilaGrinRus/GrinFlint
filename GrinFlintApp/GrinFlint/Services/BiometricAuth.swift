import Foundation
import LocalAuthentication

/// Биометрическая защита: Face ID / Touch ID на вход и на подпись.
///
/// Политика — `deviceOwnerAuthentication` (биометрия + фолбэк на код
/// устройства): отказ в биометрии или отсутствие датчика не должен
/// блокировать кошелёк безвыходно. В CI/симуляторе evaluatePolicy
/// возвращает ошибку — вызывающий код трактует это как «биометрия
/// недоступна» и пропускает дальше (пароль устройства / демо).
enum BiometricAuth {
    enum BiometricError: LocalizedError {
        case cancelled
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Требование безопасности не подтверждено."
            case .unavailable(let reason):
                return reason
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

    /// Требует биометрию (с фолбэком на код устройства).
    /// - Parameter reason: строка в диалоге системы.
    /// - Throws: `BiometricError.cancelled` при отказе/отмене.
    static func require(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Отмена"
        var nsError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &nsError) else {
            // Биометрия не настроена: не блокируем безвыходно — пропускаем.
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if !success { throw BiometricError.cancelled }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .userFallback, .systemCancel, .appCancel,
                 .authenticationFailed, .biometryLockout:
                throw BiometricError.cancelled
            default:
                // Прочие ошибки (например, симулятор без enrolled датчика) —
                // не блокируем кошелёк.
                return
            }
        }
    }
}
