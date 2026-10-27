import Foundation

/// Фабрика блокчейн-сервиса.
///
/// GRINFFI-режим (сборка в CI с XCFramework): настоящий кошелёк grin-wallet
/// поверх Rust-FFI, данные в Documents, пароль в Keychain.
/// Без GRINFFI: демо-реализация (MockWalletService).
enum WalletFactory {
    static let defaultNodeURL = "https://grinnode.live:3413"

    /// Адрес ноды из настроек (UserDefaults) или дефолт.
    static var nodeURL: String {
        get {
            UserDefaults.standard.string(forKey: "nodeURL") ?? Self.defaultNodeURL
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
                chain: .floonet, // пока только тестнет; mainnet — Фаза 4
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
