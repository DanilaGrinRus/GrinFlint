import SwiftUI

/// Экран блокировки: поверх всего UI, контент под ним скрыт.
/// Разблокировка — биометрия (с фолбэком на код устройства).
struct LockScreenView: View {
    @Bindable var lock: AppLockManager
    @State private var shake = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(26)
                    .background(Theme.surfaceLight)
                    .clipShape(Circle())
                    .offset(x: shake ? -8 : 0)
                    .animation(
                        shake
                            ? .default.repeatCount(3, autoreverses: true)
                            : .default,
                        value: shake
                    )

                VStack(spacing: 6) {
                    Text("Кошелёк заблокирован")
                        .font(Theme.rounded(22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Подтвердите личность для продолжения")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await unlock() }
                } label: {
                    if lock.isAuthenticating {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Label(
                            "Разблокировать через \(BiometricAuth.displayName)",
                            systemImage: "faceid"
                        )
                    }
                }
                .buttonStyle(GrinButtonStyle())
                .disabled(lock.isAuthenticating)
                Spacer()
            }
            .padding(24)
        }
        // Системный биометрический диалог вызывается при появлении экрана.
        .onAppear {
            Task { await unlock() }
        }
    }

    private func unlock() async {
        await lock.unlock()
        if lock.isLocked {
            shake = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shake = false }
        }
    }
}
