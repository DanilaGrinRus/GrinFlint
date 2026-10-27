import Foundation

/// Параметры экрана блокировки (интервал неактивности).
enum WalletLock {
    enum Interval: Int, CaseIterable, Identifiable {
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case thirtyMinutes = 1800

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .oneMinute: return "1 минута"
            case .fiveMinutes: return "5 минут"
            case .fifteenMinutes: return "15 минут"
            case .thirtyMinutes: return "30 минут"
            }
        }
    }

    static let requireBiometricsKey = "requireBiometrics"
    static let autoLockIntervalKey = "autoLockInterval"

    static let defaults = UserDefaults.standard

    /// Включена ли защита входа. Выключенная защита отключает и автоблокировку.
    static var isProtectionEnabled: Bool {
        get { defaults.bool(forKey: requireBiometricsKey) }
        set { defaults.set(newValue, forKey: requireBiometricsKey) }
    }

    static var autoLockInterval: Interval {
        get {
            Interval(rawValue: defaults.integer(forKey: autoLockIntervalKey)) ?? .oneMinute
        }
        set { defaults.set(newValue.rawValue, forKey: autoLockIntervalKey) }
    }
}
