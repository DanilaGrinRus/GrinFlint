import SwiftUI
import UIKit

/// Сцена, в которой сейчас виден интерфейс приложения.
@MainActor
private func frontWindowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
}

/// Показывает экран блокировки в отдельном окне поверх всего приложения.
///
/// Обычный SwiftUI `.overlay` не закрывает открытые sheet: модальный экран
/// рисуется выше базовой иерархии, и данные остаются видны. Отдельное окно
/// уровня alert перекрывает и sheet, и алерты.
@MainActor
final class LockScreenPresenter {
    static let shared = LockScreenPresenter()

    private var window: UIWindow?

    func setLocked(_ locked: Bool, lock: AppLockManager) {
        if locked {
            show(lock: lock)
        } else {
            hide()
        }
    }

    private func show(lock: AppLockManager) {
        guard window == nil else { return }
        guard let scene = frontWindowScene() else { return }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: LockScreenView(lock: lock))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }

    private func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// Закрывает содержимое приложения, когда оно не активно (переключатель
/// приложений, системный диалог, переход в фон). Суммы, адреса, seed и
/// Slatepack не должны попадать в снимок экрана — включая открытые sheet.
@MainActor
final class PrivacyShieldPresenter {
    static let shared = PrivacyShieldPresenter()

    private var window: UIWindow?

    /// active = true — приложение на экране, щит убран.
    func setActive(_ active: Bool) {
        if active {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        guard window == nil else { return }
        guard let scene = frontWindowScene() else { return }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 2
        window.backgroundColor = UIColor(Theme.background)
        let host = UIHostingController(rootView: PrivacyShieldView())
        host.view.backgroundColor = UIColor(Theme.background)
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }

    private func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// Нейтральный экран вместо содержимого кошелька.
struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("GrinFlint")
                    .font(Theme.rounded(20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Содержимое скрыто")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
