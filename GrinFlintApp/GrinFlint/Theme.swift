import SwiftUI

/// Тёмная тема Flint: холодный графитово-синий фон, мятный акцент.
/// Токены синхронизированы с десктопным Flint (crates/slint-ui/ui/theme.slint):
/// bg #090d11, surface #111820/#16202a, border #1d2833, text #e7eef4,
/// muted #7c8b9a/#9fb0c0, accent #6ee7b7, warning #f5c451, danger #f87171.
/// Философия: акцент — цвет данных и смысловых акцентов (адреса, суммы,
/// ссылки), кнопки — тёмные с белым текстом.
enum Theme {
    static let background = Color(hex: 0x090d11)
    static let surface = Color(hex: 0x111820)
    static let surfaceLight = Color(hex: 0x16202a)
    static let stroke = Color(hex: 0x1d2833)
    static let textPrimary = Color(hex: 0xe7eef4)
    static let textSecondary = Color(hex: 0x9fb0c0)
    static let textTertiary = Color(hex: 0x7c8b9a)

    /// Мятный акцент Flint (единственный акцентный цвет).
    static let accent = Color(hex: 0x6ee7b7)
    static let accentDim = Color(hex: 0x6ee7b7).opacity(0.15)

    static let positive = Color(hex: 0x6ee7b7)
    static let negative = Color(hex: 0xf87171)
    static let warning = Color(hex: 0xf5c451)

    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 10

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    init(hex: UInt32) {
        self = Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Основная кнопка Flint: тёмная (surface-2), белый текст — как в десктопном
/// shell; акцентным цветом подсвечиваются только иконки и ссылки.
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
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }

    private var buttonForeground: Color {
        if isDestructive { return Theme.negative }
        if isSecondary { return Theme.textPrimary }
        return Theme.textPrimary
    }

    private func buttonBackground(isPressed: Bool) -> Color {
        if isDestructive { return Theme.negative.opacity(0.12) }
        if isSecondary { return Theme.surface.opacity(isPressed ? 0.7 : 1) }
        return Theme.surfaceLight.opacity(isPressed ? 0.7 : 1)
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
