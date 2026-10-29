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
            if operation.stage == .finalized {
                return "Подпись готова — публикацию можно повторить"
            }
            if operation.stage == .posted {
                return "Отправлено в сеть, ждём подтверждения"
            }
            let amount = operation.amountDecimal.map(GrinFormat.grin) ?? ""
            return amount.isEmpty ? operation.stage.detail : "Отправка \(amount)"
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
    @State private var showCancelConfirm = false

    /// Актуальная стадия из журнала (операция могла измениться после действия).
    private var current: PendingOperation {
        if let live = viewModel.pendingOperation, live.id == operation.id {
            return live
        }
        return operation
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    stageCard
                    if current.kind == .send {
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
            .confirmationDialog(
                "Отменить перевод?",
                isPresented: $showCancelConfirm,
                titleVisibility: .visible
            ) {
                Button("Отменить перевод", role: .destructive) {
                    Task { await cancel() }
                }
                Button("Оставить", role: .cancel) {}
            } message: {
                Text("Средства вернутся в доступный баланс. После финализации отмена невозможна — останется только повтор публикации.")
            }
        }
    }

    private var stageCard: some View {
        GrinCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(current.stage.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(current.stage.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                if let destination = current.destination, !destination.isEmpty {
                    Text(destination)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let lastError = current.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sendSection: some View {
        VStack(spacing: 16) {
            GrinCard {
                CopyableField(
                    title: "Slatepack-запрос",
                    value: current.slatepack,
                    isMultiline: true
                )
            }

            ShareLink(item: current.slatepack) {
                Label("Поделиться запросом", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            if current.stage == .prepared {
                Button {
                    Task { await markRequestSent() }
                } label: {
                    Text("Запрос передан получателю")
                }
                .buttonStyle(GrinButtonStyle())
                .accessibilityIdentifier("pending.requestSent")
            }

            if current.stage.acceptsResponse {
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

                Button(role: .destructive) {
                    showCancelConfirm = true
                } label: {
                    Text("Отменить перевод…")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityIdentifier("pending.cancel")
            }

            if current.stage == .finalized {
                // Подпись уже есть; публикуем сохранённый Slate без новой подписи.
                Button {
                    Task { await repost() }
                } label: {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Опубликовать снова")
                    }
                }
                .buttonStyle(GrinButtonStyle())
                .disabled(isWorking)
                .accessibilityIdentifier("pending.repost")
            }

            if current.stage == .posted {
                Button {
                    Task { await checkConfirmation() }
                } label: {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Проверить подтверждение")
                    }
                }
                .buttonStyle(GrinButtonStyle())
                .disabled(isWorking)
                .accessibilityIdentifier("pending.refresh")
            }
        }
    }

    private var receiveSection: some View {
        VStack(spacing: 16) {
            GrinCard {
                CopyableField(
                    title: "Ответный Slatepack",
                    value: current.slatepack,
                    isMultiline: true
                )
            }
            ShareLink(item: current.slatepack) {
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

    private func markRequestSent() async {
        await viewModel.markRequestSent(operationID: current.id)
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

    private func cancel() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await viewModel.cancelPending(operationID: current.id)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func repost() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await viewModel.repostPending(operationID: current.id)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func checkConfirmation() async {
        isWorking = true
        defer { isWorking = false }
        await viewModel.refresh()
        if viewModel.pendingOperation == nil {
            dismiss()
        }
    }
}
