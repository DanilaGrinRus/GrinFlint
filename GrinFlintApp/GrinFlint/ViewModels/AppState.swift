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
    /// Текущий этап восстановления (для прогресса в онбординге).
    private(set) var restoreStage: String?

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

    /// Причина, по которой реальный сервис не поднялся (nil — всё в порядке).
    var serviceUnavailable: String? {
        service.unavailableReason
    }

    /// Разобрать ссылку `grinslate://receive?text=<slatepack>`.
    /// Возвращает текст Slatepack или nil, если ссылка не наша.
    static func slatepack(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "grinslate" else { return nil }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let text = items.first(where: { $0.name == "text" || $0.name == "data" })?.value,
           !text.isEmpty {
            return text
        }
        // grinslate://<данные> — если в host не служебное слово.
        if let host = url.host, host.lowercased() != "receive", !host.isEmpty {
            return host.removingPercentEncoding ?? host
        }
        return nil
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
        restoreStage = "Создаём кошелёк из seed-фразы…"
        Task {
            do {
                try await restoreWithProgress(mnemonic: mnemonic)
            } catch {
                onboardingError = error.localizedDescription
                restoreStage = nil
                isWorking = false
            }
        }
    }

    /// Восстановление по этапам: создание → открытие → скан выходов.
    /// Прерванное восстановление можно продолжить: если seed-файл уже создан,
    /// кошелёк просто открывается (повторная генерация не выполняется).
    private func restoreWithProgress(mnemonic: String) async throws {
        var alreadyOpened = false
        do {
            try await service.restore(mnemonic: mnemonic)
        } catch {
            restoreStage = "Кошелёк уже создан — продолжаем открытие…"
            do {
                try await service.open()
                alreadyOpened = true
            } catch {
                throw error
            }
        }

        if !alreadyOpened {
            restoreStage = "Открываем кошелёк…"
            try await service.open()
        }

        restoreStage = "Сканируем выходы с ноды — это может занять несколько минут…"
        var refreshError: String?
        do {
            try await service.refresh()
        } catch {
            // Вход не блокируем: покажем ошибку синхронизации на портфеле.
            refreshError = error.localizedDescription
        }

        restoreStage = nil
        isWorking = false
        finishOnboarding(alreadyOpened: true, warning: refreshError)
    }

    func clearOnboardingError() {
        onboardingError = nil
    }

    // MARK: Завершение онбординга

    private func finishOnboarding(alreadyOpened: Bool = false, warning: String? = nil) {
        UserDefaults.standard.set(true, forKey: "walletExists")
        let vm = WalletViewModel(service: service)
        viewModel = vm
        onboardingStep = nil
        Task {
            if alreadyOpened {
                await vm.syncFromService()
                if let warning { vm.reportError(warning) }
            } else {
                await activate()
            }
        }
    }

    private func activate() async {
        do {
            try await service.open()
        } catch {
            // Раньше ошибка открытия терялась: экран показывал нули без причины.
            viewModel?.reportError(
                String(localized: "Кошелёк не открылся: \(error.localizedDescription)")
            )
            return
        }
        await viewModel?.syncFromService()
        await viewModel?.refresh()
    }
}
