import SwiftUI

/// Онбординг: приветствие → создание кошелька (seed-фраза) / восстановление.
struct OnboardingView: View {
    @Bindable var appState: AppState

    @State private var restoreText = ""
    @State private var mode: Mode?

    enum Mode { case create, restore }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 40)
                    Image(systemName: "face.smiling.inverse")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.accent)
                    VStack(spacing: 8) {
                        Text("GrinFlint")
                            .font(Theme.rounded(32, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Некастодиальный кошелёк Grin (Mimblewimble).\nSeed-фраза хранится только на этом устройстве.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        Button {
                            mode = .create
                            appState.beginCreateWallet()
                        } label: {
                            if appState.isWorking && mode == .create {
                                ProgressView().tint(.white)
                            } else {
                                Text("Создать новый кошелёк")
                            }
                        }
                        .buttonStyle(GrinButtonStyle())

                        Button {
                            mode = .restore
                        } label: {
                            Text("Восстановить из seed-фразы")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Spacer()
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationDestination(item: $mode) { mode in
                switch mode {
                case .create:
                    CreateWalletView(appState: appState)
                case .restore:
                    RestoreWalletView(appState: appState, restoreText: $restoreText)
                }
            }
        }
        .alert("Ошибка", isPresented: .constant(appState.onboardingError != nil)) {
            Button("OK", role: .cancel) { appState.clearOnboardingError() }
        } message: {
            Text(appState.onboardingError ?? "")
        }
    }
}

/// Шаг создания: показ сгенерированной seed-фразы.
struct CreateWalletView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if case .showMnemonic(let mnemonic) = appState.onboardingStep {
                    Text("Запишите seed-фразу")
                        .font(Theme.rounded(24, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Эти 24 слова — единственный способ восстановить доступ. Без них средства невозможно вернуть.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)

                    GrinCard {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(Array(mnemonic.split(separator: " ").enumerated()), id: \.offset) { index, word in
                                HStack(spacing: 6) {
                                    Text("\(index + 1).")
                                        .font(Theme.mono(12))
                                        .foregroundStyle(Theme.textTertiary)
                                        .frame(width: 26, alignment: .trailing)
                                    Text(String(word))
                                        .font(Theme.mono(14))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                }
                            }
                        }
                    }

                    Button {
                        appState.confirmMnemonicWritten()
                    } label: {
                        Text("Я записал(а) — продолжить")
                    }
                    .buttonStyle(GrinButtonStyle())

                    Text("Перенос фразы через буфер обмена не предусмотрен: запишите её от руки или в менеджер паролей. Приложение не хранит фразу в открытом виде.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView().tint(Theme.accent)
                    Text("Генерируем seed…")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Новый кошелёк")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Шаг восстановления: ввод seed-фразы.
struct RestoreWalletView: View {
    @Bindable var appState: AppState
    @Binding var restoreText: String

    /// Высота блока, с которой начинать скан (пусто — с генезиса).
    @State private var restoreHeightText = ""

    private var wordCount: Int {
        restoreText.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }

    private var restoreHeight: UInt64? {
        let trimmed = restoreHeightText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let height = UInt64(trimmed), height > 0 else { return nil }
        return height
    }

    private var restoreHeightInvalid: Bool {
        !restoreHeightText.trimmingCharacters(in: .whitespaces).isEmpty && restoreHeight == nil
    }

    private var canRestore: Bool {
        (wordCount == 12 || wordCount == 24) && !restoreHeightInvalid && !appState.isWorking
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Восстановление кошелька")
                    .font(Theme.rounded(24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Введите 12 или 24 слова seed-фразы через пробел. После восстановления кошелёк синхронизируется с нодой и найдёт ваши выходы.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                GrinCard {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $restoreText)
                            .font(Theme.mono(14))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                        Text("Слов: \(wordCount)")
                            .font(.system(size: 12))
                            .foregroundStyle(
                                wordCount == 12 || wordCount == 24 ? Theme.positive : Theme.textTertiary
                            )
                    }
                }

                GrinCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Высота восстановления (необязательно)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        TextField("Например, 3100000", text: $restoreHeightText)
                            .keyboardType(.numberPad)
                            .font(Theme.mono(14))
                            .foregroundStyle(Theme.textPrimary)
                            .tint(Theme.accent)
                            .accessibilityIdentifier("restore.height")
                        Text("Укажите высоту блока, на котором создан кошелёк, — скан не пойдёт с самого начала. Пустое поле означает полный скан с генезиса.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        if restoreHeightInvalid {
                            Text("Высота — целое число больше нуля.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.warning)
                        }
                    }
                }

                Button {
                    appState.restore(mnemonic: restoreText, restoreHeight: restoreHeight)
                } label: {
                    if appState.isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Восстановить")
                    }
                }
                .buttonStyle(GrinButtonStyle())
                .disabled(!canRestore)
                .opacity(canRestore ? 1 : 0.5)

                if appState.isWorking, let stage = appState.restoreStage {
                    VStack(spacing: 8) {
                        ProgressView().tint(Theme.accent)
                        Text(stage)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("restore.stage")
                        Text("Восстановление можно безопасно прервать и продолжить: кошелёк создаётся один раз, повторная подпись не выполняется.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Восстановление")
        .navigationBarTitleDisplayMode(.inline)
    }
}
