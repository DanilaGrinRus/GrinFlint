import SwiftUI

/// Настройки кошелька.
struct SettingsView: View {
    @Environment(WalletViewModel.self) private var viewModel
    @Environment(AppLockManager.self) private var lock

    @AppStorage("nodeURL") private var nodeURL = WalletFactory.defaultNodeURL
    @AppStorage(WalletLock.requireBiometricsKey) private var requireBiometrics = false
    @AppStorage(WalletLock.autoLockIntervalKey) private var autoLockIntervalRaw =
        WalletLock.Interval.oneMinute.rawValue
    @State private var showSeed = false

    /// Демо-сид-фраза (НЕ используйте реальные средства с ней).
    private let demoSeed = [
        "wiggle", "planet", "frost", "oak", "letter", "bonus", "cloud",
        "silver", "market", "dream", "cactus", "velvet", "harbor", "stone",
        "window", "grape", "sunset", "anchor", "bridge", "forest",
        "copper", "meadow", "ladder", "ember"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    nodeSection
                    securitySection
                    contactsSection
                    aboutSection
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Старый дефолт mainnet-ноды в floonet-сборке заменяем на локальную.
                if WalletFactory.network == .floonet, nodeURL == WalletFactory.mainnetNodeURL {
                    nodeURL = WalletFactory.floonetNodeURL
                }
            }
        }
    }

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Адресная книга")
            GrinCard {
                NavigationLink {
                    ContactsView()
                } label: {
                    HStack {
                        Label("Контакты", systemImage: "person.2.fill")
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.addressBook")
            }
        }
    }

    private var nodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Подключение")
            GrinCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Адрес ноды Grin")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("https://node:3413", text: $nodeURL)
                        .font(Theme.mono(14))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Label(viewModel.isDemoMode
                          ? "В демо-режиме подключение не используется"
                          : "floonet-нода; применится при следующем запуске", systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Безопасность")
            GrinCard {
                VStack(spacing: 12) {
                    Toggle(
                        "Требовать \(BiometricAuth.displayName) при входе",
                        isOn: $requireBiometrics
                    )
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.textPrimary)
                    .onChange(of: requireBiometrics) { _, enabled in
                        // Включили защиту — сразу показываем экран блокировки.
                        if enabled { lock.lockNow() }
                    }

                    if requireBiometrics {
                        Divider().overlay(Theme.stroke)

                        Picker("Автоблокировка", selection: $autoLockIntervalRaw) {
                            ForEach(WalletLock.Interval.allCases) { interval in
                                Text(interval.title).tag(interval.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)

                        Divider().overlay(Theme.stroke)

                        Button {
                            lock.lockNow()
                        } label: {
                            Label("Заблокировать сейчас", systemImage: "lock.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Divider().overlay(Theme.stroke)

                    if viewModel.isDemoMode {
                        Button {
                            showSeed = true
                        } label: {
                            Label("Показать seed-фразу (демо)", systemImage: "key.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Label("Seed-фраза показывалась при создании кошелька; в открытом виде приложение её не хранит",
                              systemImage: "lock.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .alert("Seed-фраза (демо)", isPresented: $showSeed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(demoSeed.joined(separator: " ") + "\n\nНикому не показывайте эти слова — от них зависит доступ ко всем средствам.")
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "О приложении")
            GrinCard {
                VStack(spacing: 12) {
                    aboutRow(title: "Версия", value: viewModel.isDemoMode ? "0.1.0 (demo)" : "0.1.0 (ffi)")
                    aboutRow(title: "Бэкенд", value: viewModel.backendName)
                    aboutRow(title: "Монета", value: "Grin (Mimblewimble)")
                    aboutRow(title: "Основа", value: "Дизайн и UX по мотивам Flint Wallet")
                    Divider().overlay(Theme.stroke)
                    Text(viewModel.isDemoMode
                         ? "GrinFlint — некастодиальный кошелёк Grin. В этой сборке блокчейн-уровень заменён демо-реализацией."
                         : "Блокчейн-уровень — официальный grin-wallet 5.5.1 через FFI. Сборка не аудирована: не используйте реальные средства.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func aboutRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}
