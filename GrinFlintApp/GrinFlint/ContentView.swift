import SwiftUI

/// Корневой экран: онбординг, затем табы, как в Flint Wallet.
struct ContentView: View {
    @State private var appState = AppState()
    @State private var lock = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase

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
                }
            } else {
                OnboardingView(appState: appState)
            }
        }
        .preferredColorScheme(.dark)
        // Каждое касание — активность: сбрасывает таймер автоблокировки.
        .simultaneousGesture(
            TapGesture().onEnded { lock.sendActivity() }
        )
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                lock.sceneDidBecomeActive()
            case .background, .inactive:
                lock.sceneDidEnterBackground()
            @unknown default:
                break
            }
        }
        .overlay {
            // Контент полностью закрыт (как фон в десктопном shell),
            // автоблокировка безопасна только когда экран незаметен.
            if lock.isLocked {
                LockScreenView(lock: lock)
                    .transition(.opacity)
            }
        }
    }

    private var tabView: some View {
        TabView {
            PortfolioView()
                .tabItem {
                    Label("Портфель", systemImage: "chart.pie.fill")
                }
            TransactionsView()
                .tabItem {
                    Label("Транзакции", systemImage: "list.bullet")
                }
            SettingsView()
                .tabItem {
                    Label("Настройки", systemImage: "gearshape.fill")
                }
        }
        .tint(Theme.accent)
        .environment(lock)
    }

    /// Для скриншотов в CI: `-simOpen send|receive|transactions|settings`.
    private var simOpenTarget: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-simOpen"), args.count > index + 1 else {
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
