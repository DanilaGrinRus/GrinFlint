import Foundation
import Observation

/// Состояние приложения: онбординг (кошелька нет) или основной UI.
@Observable
final class AppState {
    enum OnboardingStep: Equatable {
        case welcome
        case showMnemonic(String)
    }

    /// Сервис создаётся один раз на запуск и используется и при онбординге,
    /// и в основном UI (у него же вызываются createWallet/restore).
    let service: any WalletService

    private(set) var viewModel: WalletViewModel?
    private(set) var onboardingStep: OnboardingStep?
    private(set) var isWorking = false
    private(set) var onboardingError: String?

    init() {
        service = WalletFactory.makeService()
        if UserDefaults.standard.bool(forKey: "walletExists") {
            viewModel = WalletViewModel(service: service)
            Task { await activate() }
        } else {
            onboardingStep = .welcome
        }
    }

    var isDemoMode: Bool {
        viewModel?.isDemoMode ?? true
    }

    // MARK: Онбординг

    func beginCreateWallet() {
        isWorking = true
        onboardingError = nil
        Task {
            do {
                let mnemonic = try await service.createWallet(mnemonicLength: 24)
                onboardingStep = .showMnemonic(mnemonic)
            } catch {
                onboardingError = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// Пользователь подтвердил, что записал seed-фразу.
    func confirmMnemonicWritten() {
        finishOnboarding()
    }

    func restore(mnemonic: String) {
        isWorking = true
        onboardingError = nil
        Task {
            do {
                try await service.restore(mnemonic: mnemonic)
                finishOnboarding()
            } catch {
                onboardingError = error.localizedDescription
            }
            isWorking = false
        }
    }

    func clearOnboardingError() {
        onboardingError = nil
    }

    // MARK: Завершение онбординга

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "walletExists")
        let vm = WalletViewModel(service: service)
        viewModel = vm
        onboardingStep = nil
        Task { await activate() }
    }

    private func activate() async {
        do {
            try await service.open()
            try await service.refresh()
        } catch {
            // Не блокируем UI: баланс догрузится следующим refresh().
            onboardingError = nil
        }
    }
}
