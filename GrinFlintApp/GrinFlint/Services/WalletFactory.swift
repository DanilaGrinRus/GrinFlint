import Foundation

/// Фабрика блокчейн-сервиса.
///
/// GRINFFI-режим (сборка в CI с XCFramework): настоящий кошелёк grin-wallet
/// поверх Rust-FFI, данные в Documents, пароль в Keychain.
/// Без GRINFFI: демо-реализация (MockWalletService).
enum WalletFactory {
    /// Сеть сборки. mainnet — только Фаза 4 (реальные деньги).
    enum Network: String {
        case mainnet
        case floonet
    }

    static let network: Network = .floonet

    /// Нода mainnet.
    static let mainnetNodeURL = "https://grinnode.live:3413"
    /// Нода floonet по умолчанию: локальная тестнет-нода. Порт 13413, НЕ 3413.
    static let floonetNodeURL = "http://127.0.0.1:13413"

    /// Адрес ноды по умолчанию для выбранной сети.
    static var defaultNodeURL: String {
        network == .mainnet ? mainnetNodeURL : floonetNodeURL
    }

    /// Адрес ноды из настроек (UserDefaults) или дефолт.
    static var nodeURL: String {
        get {
            guard let stored = UserDefaults.standard.string(forKey: "nodeURL"),
                  !stored.isEmpty else {
                return defaultNodeURL
            }
            // Старый дефолт mainnet в floonet-сборке не годится: другая сеть.
            if network == .floonet && stored == mainnetNodeURL {
                return floonetNodeURL
            }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "nodeURL")
        }
    }

    static func makeService() -> any WalletService {
        #if GRINFFI
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let password = try KeychainStore.loadOrCreatePassword()
            let service = try GrinWalletFFIService(
                dataDir: documents.appendingPathComponent("grin-wallet", isDirectory: true).path,
                nodeURL: Self.nodeURL,
                chain: network == .mainnet ? .mainnet : .floonet,
                password: password
            )
            return service
        } catch {
            // Не должно происходить; валимся в демо, чтобы UI остался живым.
            assertionFailure("GrinWalletFFIService init failed: \(error)")
            return MockWalletService()
        }
        #else
        return MockWalletService()
        #endif
    }
}
