import SwiftUI

/// Получение Grin: адрес кошелька + приём входящего Slatepack.
struct ReceiveView: View {
    @Environment(WalletViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var slatepackInput: String
    @State private var receivedTx: TransactionRecord?
    @State private var isWorking = false
    @State private var validationError: String?
    @State private var qrImage: UIImage?

    /// `initialSlatepack` — текст из ссылки `grinslate://` или из буфера.
    init(initialSlatepack: String = "") {
        _slatepackInput = State(initialValue: initialSlatepack)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                myAddressSection
                incomingSection
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Получить GRIN")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Ошибка", isPresented: .constant(validationError != nil)) {
            Button("OK") { validationError = nil }
        } message: {
            Text(validationError ?? "")
        }
        .sheet(item: $receivedTx) { tx in
            ReceiveResultSheet(tx: tx) {
                receivedTx = nil
                dismiss()
            }
        }
        .task(id: viewModel.slatepackAddress) {
            // QR пересчитывается только при смене адреса.
            qrImage = QRCode.image(for: viewModel.slatepackAddress)
        }
    }

    private var myAddressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Ваш адрес")
            GrinCard {
                VStack(spacing: 12) {
                    CopyableField(title: "Grin-адрес", value: viewModel.slatepackAddress)
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 168, height: 168)
                            .padding(10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityIdentifier("receive.qr")
                    }
                    Label("По этому адресу можно получать Slatepack-ответы",
                          systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var incomingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Принять Slatepack от отправителя")
            GrinCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Вставьте Slatepack-сообщение, которое вам прислали:")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)

                    TextEditor(text: $slatepackInput)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        Task { await accept() }
                    } label: {
                        if isWorking {
                            ProgressView().tint(.white)
                        } else {
                            Text("Принять и зачислить")
                        }
                    }
                    .buttonStyle(GrinButtonStyle())
                    .disabled(slatepackInput.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }
            }
        }
    }

    private func accept() async {
        validationError = nil
        // Приём (подпись ответного slate) защищён биометрией (Фаза 2).
        if WalletLock.isProtectionEnabled {
            do {
                try await BiometricAuth.require(reason: "Подтвердите приём средств")
            } catch {
                validationError = error.localizedDescription
                return
            }
        }
        isWorking = true
        defer { isWorking = false }
        do {
            receivedTx = try await viewModel.receive(slatepack: slatepackInput)
        } catch let error as WalletError {
            validationError = error.localizedDescription
        } catch {
            validationError = error.localizedDescription
        }
    }
}

/// Итог приёма транзакции.
struct ReceiveResultSheet: View {
    let tx: TransactionRecord
    let onDone: () -> Void

    private var needsReply: Bool { tx.responseSlatepack != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: needsReply ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.positive)

                    VStack(spacing: 6) {
                        Text(needsReply ? "Slatepack принят" : "Транзакция принята")
                            .font(Theme.rounded(22, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(needsReply
                             ? "Отправьте ответный Slatepack отправителю — без этого средства не придут"
                             : "Средства зачислены после подтверждения блока")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    if tx.amount > 0 {
                        GrinCard {
                            HStack {
                                Text("Получено")
                                Spacer()
                                Text("+\(GrinFormat.grin(tx.amount))")
                                    .font(Theme.mono(16))
                                    .foregroundStyle(Theme.positive)
                            }
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                        }
                    }

                    if let response = tx.responseSlatepack {
                        CopyableField(title: "Ответный Slatepack для отправителя", value: response, isMultiline: true)
                        Text("Отправитель вставит его в приложение и завершит перевод. После подтверждения обновите баланс.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    Button("Готово", action: onDone)
                        .buttonStyle(GrinButtonStyle())
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
