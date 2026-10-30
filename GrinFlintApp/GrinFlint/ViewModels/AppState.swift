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

    /// `restoreHeight` — необязательная высота блока, с которой начинать скан
    /// (nil — с генезиса; полезно, когда известен возраст кошелька).
    func restore(mnemonic: String, restoreHeight: UInt64? = nil) {
        isWorking = true
        onboardingError = nil
        restoreStage = "Проверяем seed-фразу…"
        Task {
            do {
                // Адрес, который обязан быть у этого seed. Считается на
                // временном кошельке: данные приложения не затрагиваются.
                let expected = try await service.address(forMnemonic: mnemonic)
                try await restoreWithProgress(
                    mnemonic: mnemonic,
                    restoreHeight: restoreHeight,
                    expectedAddress: expected
                )
            } catch {
                onboardingError = error.localizedDescription
                restoreStage = nil
                isWorking = false
            }
        }
    }

    /// Восстановление по этапам, с обязательной сверкой seed → адрес.
    ///
    /// Ошибка восстановления больше не приводит к слепому открытию прежнего
    /// кошелька: если кошелёк уже существует, он открывается, но адрес обязан
    /// совпасть с адресом введённой фразы. Иначе восстановление остановлено,
    /// данные не изменяются.
    private func restoreWithProgress(
        mnemonic: String,
        restoreHeight: UInt64?,
        expectedAddress: String
    ) async throws {
        var openedExisting = false
        do {
            try await service.open()
            openedExisting = true
            restoreStage = "Сверяем кошелёк с seed-фразой…"
        } catch {
            // Кошелька нет (или он не открылся) — создаём из фразы ниже.
            openedExisting = false
        }

        if !openedExisting {
            restoreStage = "Создаём кошелёк из seed-фразы…"
            try await service.restore(mnemonic: mnemonic, restoreHeight: restoreHeight)
            restoreStage = "Открываем кошелёк…"
            try await service.open()
        }

        let actual = await service.slatepackAddress
        guard actual == expectedAddress else {
            throw WalletError.seedMismatch
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
