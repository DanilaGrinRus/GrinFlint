import SwiftUI

/// Корневой экран с табами, как в Flint Wallet.
struct ContentView: View {
    @State private var viewModel = WalletViewModel()

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.surface)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
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
        .environment(viewModel)
        .preferredColorScheme(.dark)
    }
}
