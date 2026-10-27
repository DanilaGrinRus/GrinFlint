import SwiftUI

/// Пошаговая отправка Grin через Slatepack.
struct SendFlowView: View {
    @Environment(WalletViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    @State private var destination = ""
    @State private var amountText = ""
    @State private var message = ""
    @State private var feeTier: FeeTier = .standard
    @State private var proposal: SendProposal?
    @State private var isWorking = false
    @State private var sendError: String?

    private var parsedAmount: Decimal? { GrinFormat.parse(amountText) }
    private var trimmedDestination: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canProceed: Bool { parsedAmount != nil && !trimmedDestination.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                destinationSection
                amountSection
                messageSection
                feeSection
                Button {
                    Task { await prepare() }
                } label: {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Создать транзакцию")
                    }
                }
                .buttonStyle(GrinButtonStyle())
                .disabled(!canProceed || isWorking)
                .opacity(canProceed ? 1 : 0.5)
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Отправить GRIN")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $proposal) { proposal in
            SendResultSheet(proposal: proposal) {
                self.proposal = nil
                dismiss()
            }
        }
        .alert("Не удалось создать транзакцию", isPresented: .constant(sendError != nil)) {
            Button("OK") { sendError = nil }
        } message: {
            Text(sendError ?? "")
        }
    }

    private var destinationSection: some View {
        GrinCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Адрес получателя (Slatepack)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                TextField("grin1…", text: $destination)
                    .font(Theme.mono(14))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        }
    }

    private var amountSection: some View {
        GrinCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Сумма")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("0.0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(Theme.rounded(34, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                    Text("GRIN")
                        .font(Theme.rounded(20, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }

                HStack {
                    Text("Доступно: \(GrinFormat.grin(viewModel.balance.spendable))")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Максимум") {
                        amountText = GrinFormat.short(viewModel.balance.spendable - feeTier.fee)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var messageSection: some View {
        GrinCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Сообщение (опционально)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Например: за кофе", text: $message)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
            }
        }
    }

    private var feeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Комиссия сети")
            HStack(spacing: 10) {
                ForEach(FeeTier.allCases) { tier in
                    Button {
                        feeTier = tier
                    } label: {
                        VStack(spacing: 6) {
                            Text(tier.title)
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(GrinFormat.short(tier.fee)) GRIN")
                                .font(Theme.mono(12))
                            Text(tier.eta)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(feeTier == tier ? .black : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(feeTier == tier ? Theme.accent : Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(feeTier == tier ? Color.clear : Theme.stroke, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func prepare() async {
        guard let amount = parsedAmount else { return }
        // Подпись транзакции защищена биометрией (Фаза 2).
        if WalletLock.isProtectionEnabled {
            do {
                try await BiometricAuth.require(reason: "Подтвердите отправку средств")
            } catch {
                sendError = error.localizedDescription
                return
            }
        }
        isWorking = true
        defer { isWorking = false }
        do {
            proposal = try await viewModel.prepareSend(
                destination: trimmedDestination,
                amount: amount,
                message: message.trimmingCharacters(in: .whitespaces),
                feeTier: feeTier
            )
        } catch let error as WalletError {
            sendError = error.localizedDescription
        } catch {
            sendError = error.localizedDescription
        }
    }
}

/// Итог отправки: Slatepack для передачи контрагенту.
struct SendResultSheet: View {
    let proposal: SendProposal
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.positive)

                    VStack(spacing: 6) {
                        Text("Транзакция создана")
                            .font(Theme.rounded(22, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Средства заблокированы до подтверждения")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    GrinCard {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Сумма")
                                Spacer()
                                Text(GrinFormat.grin(proposal.amount))
                                    .font(Theme.mono(15))
                            }
                            HStack {
                                Text("Комиссия")
                                Spacer()
                                Text(GrinFormat.grin(proposal.fee))
                                    .font(Theme.mono(15))
                            }
                            Divider().overlay(Theme.stroke)
                            HStack {
                                Text("Итого")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text(GrinFormat.grin(proposal.amount + proposal.fee))
                                    .font(Theme.mono(15, weight: .semibold))
                            }
                        }
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                    }

                    CopyableField(title: "Slatepack для получателя", value: proposal.slatepack, isMultiline: true)

                    Text("Передайте этот Slatepack получателю любым способом — в Grin транзакции завершаются совместно.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)

                    Button("Готово", action: onDone)
                        .buttonStyle(GrinButtonStyle())
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

extension SendProposal: Identifiable {
    var id: UUID { txID }
}
