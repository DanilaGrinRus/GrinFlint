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
            if let viewModel = appState.viewModel {
                tabView
                    .environment(viewModel)
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
}
