import SwiftUI

/// Экран, когда реальный сервис кошелька не поднялся.
///
/// Раньше в этом случае приложение молча переключалось на демо-баланс —
/// для кошелька это недопустимо, поэтому теперь показываем причину честно.
struct StartupErrorView: View {
    let reason: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.warning)

            Text("Кошелёк не запустился")
                .font(Theme.rounded(24, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Text(reason)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            Text("Закройте и откройте приложение заново. Если ошибка повторяется — проверьте адрес ноды и свободное место на устройстве.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}
