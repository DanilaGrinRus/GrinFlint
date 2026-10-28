import SwiftUI

/// Карточка незавершённого перевода на портфеле: этап и продолжение.
struct PendingOperationCard: View {
    let operation: PendingOperation
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            GrinCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(Theme.warning)
                        Text("Незавершённый перевод")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(operation.stage.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pending.operation")
        .sheet(isPresented: $showSheet) {
            PendingOperationSheet(operation: operation)
        }
    }

    private var summary: String {
        switch operation.kind {
        case .send:
            let amount = operation.amountDecimal.map(GrinFormat.grin) ?? ""
            return amount.isEmpty ? "Отправка ждёт ответа получателя" : "Отправка \(amount) ждёт ответа"
        case .receive:
            return "Ответ для отправителя готов — передайте его любым способом"
        }
    }
}

/// Экран продолжения: показать Slatepack, передать его и завершить перевод.
struct PendingOperationSheet: View {
    @Environment(WalletViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    let operation: PendingOperation

    @State private var response = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    stageCard
                    if operation.kind == .send {
                        sendSection
                    } else {
                        receiveSection
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Незавершённый перевод")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .alert("Ошибка", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private var stageCard: some View {
        GrinCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(operation.stage.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(stepText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                if let destination = operation.destination, !destination.isEmpty {
                    Text(destination)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stepText: String {
        switch operation.kind {
        case .send:
            return "Этап 2 из 3: передайте запрос получателю и вставьте его ответ ниже."
        case .receive:
            return "Этап 3 из 3: передайте ответ отправителю — он завершит перевод."
        }
    }

    private var sendSection: some View {
        VStack(spacing: 16) {
            GrinCard {
                CopyableField(
                    title: "Slatepack-запрос",
                    value: operation.slatepack,
                    isMultiline: true
                )
            }

            ShareLink(item: operation.slatepack) {
                Label("Поделиться запросом", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            GrinCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ответ получателя")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    TextEditor(text: $response)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("pending.response")
                    Button {
                        Task { await complete() }
                    } label: {
                        if isWorking {
                            ProgressView().tint(.white)
                        } else {
                            Text("Завершить перевод")
                        }
                    }
                    .buttonStyle(GrinButtonStyle())
                    .disabled(
                        response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking
                    )
                }
            }
        }
    }

    private var receiveSection: some View {
        VStack(spacing: 16) {
            GrinCard {
                CopyableField(
                    title: "Ответный Slatepack",
                    value: operation.slatepack,
                    isMultiline: true
                )
            }
            ShareLink(item: operation.slatepack) {
                Label("Поделиться ответом", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            Button {
                Task { await viewModel.dismissPending(); dismiss() }
            } label: {
                Text("Готово — ответ передан")
            }
            .buttonStyle(GrinButtonStyle())
        }
    }

    private func complete() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await viewModel.finalize(slatepackResponse: response)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
