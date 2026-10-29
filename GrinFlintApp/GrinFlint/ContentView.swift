import SwiftUI

/// Корневой экран: онбординг, затем табы, как в Flint Wallet.
struct ContentView: View {
    @State private var appState = AppState()
    @State private var lock = AppLockManager()
    @State private var addressBook = AddressBook()
    @State private var incoming: IncomingSlatepack?
    @Environment(\.scenePhase) private var scenePhase

    /// Slatepack из ссылки `grinslate://` (лист приёма поверх основного UI).
    private struct IncomingSlatepack: Identifiable {
        let id = UUID()
        let text: String
    }

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.surface)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        Group {
            if let reason = appState.serviceUnavailable {
                // Реальный сервис не поднялся: показываем причину, а не демо.
                StartupErrorView(reason: reason)
            } else if let viewModel = appState.viewModel {
                if let target = simOpenTarget {
                    // Скриншоты в CI: сразу нужный экран, без тапов.
                    SimScreenHost(target: target)
                        .environment(viewModel)
                        .environment(lock)
                } else {
                    tabView
                        .environment(viewModel)
                        .sheet(item: $incoming) { item in
                            NavigationStack {
                                ReceiveView(initialSlatepack: item.text)
                            }
                            .environment(viewModel)
                        }
                }
            } else {
                OnboardingView(appState: appState)
            }
        }
        .preferredColorScheme(.dark)
        .environment(addressBook)
        .onOpenURL { url in
            if let text = AppState.slatepack(from: url) {
                incoming = IncomingSlatepack(text: text)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                PrivacyShieldPresenter.shared.setActive(true)
                lock.sceneDidBecomeActive()
            case .inactive:
                // Системный диалог/переключатель: скрываем содержимое, но
                // не создаём новую блокировку (её даёт уход в фон).
                PrivacyShieldPresenter.shared.setActive(false)
                lock.sceneWillResignActive()
            case .background:
                PrivacyShieldPresenter.shared.setActive(false)
                lock.sceneDidEnterBackground()
            @unknown default:
                break
            }
        }
        .onChange(of: lock.isLocked) { _, locked in
            if locked {
                // Ссылка/лист приёма не должны оставаться поверх блокировки.
                incoming = nil
            }
            LockScreenPresenter.shared.setLocked(locked, lock: lock)
        }
        .task {
            // Приложение могло стартовать сразу заблокированным.
            LockScreenPresenter.shared.setLocked(lock.isLocked, lock: lock)
            PrivacyShieldPresenter.shared.setActive(scenePhase == .active)
            if let text = simIncomingArgument {
                incoming = IncomingSlatepack(text: text)
            }
        }
    }

    private var tabView: some View {
        TabView {
            PortfolioView()
                .simultaneousGesture(activityTap)
                .tabItem {
                    Label("Портфель", systemImage: "chart.pie.fill")
                }
            TransactionsView()
                .simultaneousGesture(activityTap)
                .tabItem {
                    Label("Транзакции", systemImage: "list.bullet")
                }
            SettingsView()
                .simultaneousGesture(activityTap)
                .tabItem {
                    Label("Настройки", systemImage: "gearshape.fill")
                }
        }
        .tint(Theme.accent)
        .environment(lock)
    }

    /// Касание по контенту — активность для автоблокировки. Жест намеренно
    /// висит на контенте вкладки, а не на корне: на корне он перехватывал
    /// тапы по UIKit-таббару (проверено XCUITest).
    private var activityTap: some Gesture {
        TapGesture().onEnded { lock.sendActivity() }
    }

    /// Для скриншотов в CI: `-simOpen send|receive|transactions|settings`.
    private var simOpenTarget: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-simOpen"), args.count > index + 1 else {
            return nil
        }
        return args[index + 1]
    }

    /// Для XCUITest: `-simIncoming <slatepack>` открывает лист приёма.
    private var simIncomingArgument: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-simIncoming"), args.count > index + 1 else {
            return nil
        }
        return args[index + 1]
    }
}

/// Прямой показ одного экрана для скриншотов. В обычном запуске не используется.
struct SimScreenHost: View {
    let target: String

    var body: some View {
        switch target {
        case "send":
            NavigationStack { SendFlowView() }
        case "receive":
            NavigationStack { ReceiveView() }
        case "transactions":
            TransactionsView()
        case "settings":
            SettingsView()
        default:
            Text("Неизвестный экран: \(target)")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
        }
    }
}
