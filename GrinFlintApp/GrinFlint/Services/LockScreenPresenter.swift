import SwiftUI
import UIKit

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
        guard let scene = activeScene() else { return }

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

    private func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }
}
