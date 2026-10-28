import SwiftUI
import UniformTypeIdentifiers

/// Пошаговая отправка Grin через Slatepack.
struct SendFlowView: View {
    @Environment(WalletViewModel.self) private var viewModel
    @Environment(AddressBook.self) private var addressBook
    @Environment(\.dismiss) private var dismiss

    @State private var destination = ""
    @State private var amountText = ""
    @State private var feeTier: FeeTier = .standard
    @State private var proposal: SendProposal?
    @State private var isWorking = false
    @State private var sendError: String?
    @State private var isScanning = false

    private var parsedAmount: Decimal? { GrinFormat.parse(amountText) }
    private var trimmedDestination: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canProceed: Bool { parsedAmount != nil && !trimmedDestination.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                destinationSection
                amountSection
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
            SendResultSheet(
                proposal: proposal,
                requiresFinalize: !viewModel.isDemoMode,
                onFinalize: { response in
                    try await viewModel.finalize(slatepackResponse: response)
                },
                onDone: {
                    self.proposal = nil
                    dismiss()
                }
            )
        }
        .alert("Не удалось создать транзакцию", isPresented: .constant(sendError != nil)) {
            Button("OK") { sendError = nil }
        } message: {
            Text(sendError ?? "")
        }
        .sheet(isPresented: $isScanning) {
            scannerSheet
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            QRScannerView { code in
                destination = code
                isScanning = false
            }
            .ignoresSafeArea()
            .navigationTitle("Сканировать QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { isScanning = false }
                }
            }
        }
    }

    private var destinationSection: some View {
        GrinCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Адрес получателя (Slatepack)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    TextField("grin1…", text: $destination)
                        .font(Theme.mono(14))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("send.destination")
                    Button {
                        isScanning = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("send.scan")
                }
                if !addressBook.contacts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(addressBook.contacts) { contact in
                                Button {
                                    destination = contact.address
                                } label: {
                                    Text(contact.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Theme.accentDim)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("send.contact")
                            }
                        }
                    }
                }
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
                        .accessibilityIdentifier("send.amount")
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
                amountText: amountText,
                feeTier: feeTier
            )
        } catch let error as WalletError {
            sendError = error.localizedDescription
        } catch {
            sendError = error.localizedDescription
        }
    }
}

/// Итог отправки: Slatepack для получателя и (в FFI-режиме) шаг завершения
/// ответным Slatepack — без него транзакция в Grin не попадает в сеть.
struct SendResultSheet: View {
    let proposal: SendProposal
    let requiresFinalize: Bool
    let onFinalize: (String) async throws -> Void
    let onDone: () -> Void

    @State private var response = ""
    @State private var isWorking = false
    @State private var isFinished = false
    @State private var finalizeError: String?
    @State private var showImporter = false

    private var stageText: String {
        if isFinished {
            return "Этап 3 из 3: перевод отправлен в сеть"
        }
        if requiresFinalize {
            return "Этап 2 из 3: передайте запрос получателю и вставьте его ответ ниже"
        }
        return "Демо-режим: запрос не уходит в сеть"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    Text(stageText)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    summaryCard

                    if !requiresFinalize {
                        CopyableField(title: "Slatepack для получателя", value: proposal.slatepack, isMultiline: true)
                        Text("Передайте этот Slatepack получателю любым способом — в Grin транзакции завершаются совместно.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    } else if isFinished {
                        Label("Перевод отправлен в сеть", systemImage: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.positive)
                        Text("Подтверждение появится в истории после обновления баланса.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    } else {
                        CopyableField(title: "Slatepack для получателя", value: proposal.slatepack, isMultiline: true)
                        ShareLink(item: proposal.slatepack) {
                            Label("Поделиться запросом", systemImage: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        finalizeSection
                    }

                    Button("Готово", action: onDone)
                        .buttonStyle(GrinButtonStyle())
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationBarHidden(true)
            .alert("Не удалось завершить перевод", isPresented: .constant(finalizeError != nil)) {
                Button("OK") { finalizeError = nil }
            } message: {
                Text(finalizeError ?? "")
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.plainText, .data]
            ) { result in
                importResponseFile(result)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: isFinished ? "paperplane.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(isFinished ? Theme.positive : Theme.accent)
            Text(isFinished ? "Перевод завершён" : "Транзакция создана")
                .font(Theme.rounded(22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(isFinished ? "Средства ушли в сеть" : "Средства заблокированы до завершения")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var summaryCard: some View {
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
    }

    private var finalizeSection: some View {
        GrinCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ответный Slatepack от получателя")
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

                Button {
                    Task { await finish() }
                } label: {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Завершить перевод")
                    }
                }
                .buttonStyle(GrinButtonStyle())
                .disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)

                Button {
                    showImporter = true
                } label: {
                    Label("Импортировать ответ из файла", systemImage: "doc.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Импорт ответного Slatepack из файла (наряду с вставкой и QR).
    private func importResponseFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                response = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                finalizeError = "Не удалось прочитать файл как текст (UTF-8)."
            }
        case .failure(let error):
            finalizeError = error.localizedDescription
        }
    }

    private func finish() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await onFinalize(response)
            isFinished = true
        } catch {
            finalizeError = error.localizedDescription
        }
    }
}

extension SendProposal: Identifiable {
    var id: UUID { txID }
}
