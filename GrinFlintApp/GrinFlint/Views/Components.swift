import SwiftUI

/// Строка транзакции для списков.
struct TxRow: View {
    let tx: TransactionRecord

    private var isIncoming: Bool { tx.type != .sent }
    private var amountColor: Color { isIncoming ? Theme.positive : Theme.textPrimary }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isIncoming ? Theme.positive.opacity(0.12) : Theme.surfaceLight)
                    .frame(width: 40, height: 40)
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isIncoming ? Theme.positive : Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(amountText)
                    .font(Theme.mono(15))
                    .foregroundStyle(amountColor)
                Text(tx.status.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch tx.type {
        case .sent: return "arrow.up.right"
        case .received: return "arrow.down.left"
        case .coinbase: return "hammer.fill"
        }
    }

    private var title: String {
        switch tx.type {
        case .sent: return "Отправлено"
        case .received: return "Получено"
        case .coinbase: return "Награда за блок"
        }
    }

    private var subtitle: String {
        if let message = tx.message.nilIfEmpty {
            return message
        }
        return TxDate.section(tx.createdAt)
    }

    private var amountText: String {
        let sign = isIncoming ? "+" : ""
        return "\(sign)\(GrinFormat.short(tx.amount.magnitude))"
    }

    private var statusColor: Color {
        switch tx.status {
        case .confirmed: return Theme.textTertiary
        case .unconfirmed: return Theme.warning
        case .reverted: return Theme.warning
        case .failed: return Theme.negative
        }
    }
}

/// Плашка копирования длинного текста (адрес, Slatepack).
struct CopyableField: View {
    let title: String
    let value: String
    var isMultiline = false

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .tracking(0.6)
                Spacer()
                Button {
                    UIPasteboard.general.string = value
                    withAnimation(.snappy) { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Скопировано" : "Копировать",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(copied ? Theme.positive : Theme.accent)
                }
            }

            if isMultiline {
                ScrollView {
                    Text(value)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(12)
                .background(Color.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text(value)
                    .font(Theme.mono(14))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Индикатор ошибки поверх контента.
struct ErrorBanner: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(Theme.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
    }
}
