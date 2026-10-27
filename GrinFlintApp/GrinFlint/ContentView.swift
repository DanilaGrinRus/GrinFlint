import SwiftUI

/// Корневой экран: онбординг, затем табы, как в Flint Wallet.
struct ContentView: View {
    @State private var appState = AppState()

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
    }
}
