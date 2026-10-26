import SwiftUI

/// Тёмная тема в духе Flint Wallet с фирменным жёлтым акцентом Grin.
enum Theme {
    static let background = Color(.black).opacity(0.98)
    static let surface = Color(white: 0.11)
    static let surfaceLight = Color(white: 0.16)
    static let stroke = Color.white.opacity(0.08)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)
    static let textTertiary = Color.white.opacity(0.38)

    /// Фирменный жёлтый Grin.
    static let accent = Color(red: 0.996, green: 0.945, blue: 0.008)
    static let accentDim = Color(red: 0.996, green: 0.945, blue: 0.008).opacity(0.15)

    static let positive = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let negative = Color(red: 0.96, green: 0.35, blue: 0.39)
    static let warning = Color(red: 0.98, green: 0.65, blue: 0.10)

    static let cardRadius: CGFloat = 20

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Основная кнопка в стиле Flint (жёлтая, круглая).
struct GrinButtonStyle: ButtonStyle {
    var isDestructive = false
    var isSecondary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(17))
            .foregroundStyle(buttonForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(buttonBackground(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var buttonForeground: Color {
        if isDestructive { return Theme.negative }
        if isSecondary { return Theme.textPrimary }
        return .black
    }

    private func buttonBackground(isPressed: Bool) -> Color {
        if isDestructive { return Theme.negative.opacity(0.15) }
        if isSecondary { return Theme.surfaceLight.opacity(isPressed ? 0.7 : 1) }
        return Theme.accent.opacity(isPressed ? 0.8 : 1)
    }
}

/// Карточка поверх тёмного фона.
struct GrinCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .tracking(0.8)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 4)
    }
}
