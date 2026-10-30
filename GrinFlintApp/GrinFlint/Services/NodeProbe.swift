import Foundation

/// Проверка ноды Grin: доступность и совместимость сети.
///
/// Сеть определяется по genesis-блоку ноды (foreign API `get_header` высоты 0)
/// и сравнивается с genesis-хешем сети кошелька, который отдаёт FFI
/// (`grin_wallet_chain_genesis`). Так исключается подключение floonet-кошелька
/// к mainnet-ноде: это разные цепи, и средства/выходы в них несовместимы.
///
/// На физическом iPhone `127.0.0.1` указывает на сам телефон, поэтому такой
/// адрес отсекается с объяснением (в симуляторе он допустим — там нода
/// обычно на том же Mac).
enum NodeProbe {
    struct Result {
        var chain: String        // "mainnet" | "testnet"
        var height: UInt64       // высота genesis (0) — маркер ответа ноды
        var genesisPrefix: String
    }

    enum ProbeError: LocalizedError {
        case invalidURL(String)
        case localhostOnDevice
        case noFFI
        case unreachable(String)
        case unauthorized
        case unknownChain
        case wrongChain(found: String, expected: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let detail):
                return "Адрес ноды некорректен: \(detail). Пример: http://192.168.1.10:13413"
            case .localhostOnDevice:
                return "127.0.0.1 на iPhone указывает на сам телефон, а не на компьютер с нодой. Укажите LAN-адрес компьютера (например, http://192.168.1.10:13413) или внешний адрес ноды."
            case .noFFI:
                return "Проверка сети ноды доступна только в сборке с реальным grin-wallet (FFI)."
            case .unreachable(let detail):
                return "Нода недоступна: \(detail). Проверьте адрес, порт (13413 для testnet, 3413 для mainnet) и что нода запущена."
            case .unauthorized:
                return "Нода требует API-секрет (Basic Auth, пользователь grin). Укажите секрет в настройках — он хранится в Keychain."
            case .unknownChain:
                return "Нода ответила, но её genesis-блок не совпал с ожидаемым. Это другая цепь — подключаться к ней нельзя."
            case .wrongChain(let found, let expected):
                return "Нода работает в сети \(found), а кошелёк — в \(expected). Укажите ноду своей сети: данные и средства другой цепи не подходят."
            }
        }
    }

    /// Проверить ноду и сверить сеть с текущей сборкой.
    static func check(
        urlString: String,
        expected: WalletFactory.Network,
        apiSecret: String? = nil
    ) async throws -> Result {
        let url = try validated(urlString)
        let expectedChain = expectName(expected)

        #if GRINFFI
        let expectedGenesis: GrinChainGenesis = try GrinFFI.callStandalone(
            { grin_wallet_chain_genesis(expectedChain) },
            as: GrinChainGenesis.self
        )
        let remote = try await fetchGenesis(url: url, apiSecret: apiSecret)
        guard let remoteHash = remote.hash, !remoteHash.isEmpty else {
            throw ProbeError.unknownChain
        }
        guard remoteHash.lowercased() == expectedGenesis.hash.lowercased() else {
            throw ProbeError.wrongChain(found: "другая сеть", expected: expectedChain)
        }
        return Result(
            chain: expectedChain,
            height: remote.height ?? 0,
            genesisPrefix: String(remoteHash.prefix(16))
        )
        #else
        throw ProbeError.noFFI
        #endif
    }

    private static func expectName(_ network: WalletFactory.Network) -> String {
        network == .mainnet ? "mainnet" : "testnet"
    }

    // MARK: - Запрос к ноде

    private struct RemoteHeader: Decodable {
        var hash: String?
        var height: UInt64?
    }

    private struct JSONRPCResponse<T: Decodable>: Decodable {
        struct Envelope<T2: Decodable>: Decodable {
            let Ok: T2?
            let Err: String?
        }
        let result: Envelope<T>?
        let error: RPCError?
    }

    private struct RPCError: Decodable {
        let code: Int?
        let message: String?
    }

    private static func fetchGenesis(url: String, apiSecret: String?) async throws -> RemoteHeader {
        guard let endpoint = URL(string: url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v2/foreign") else {
            throw ProbeError.invalidURL("не удалось собрать URL")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        if let secret = apiSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
           !secret.isEmpty {
            let credentials = Data("grin:\(secret)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "get_header",
            "params": [0, NSNull(), NSNull()],
            "id": 1,
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProbeError.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProbeError.unauthorized
            }
            if !(200...299).contains(http.statusCode) {
                throw ProbeError.unreachable("HTTP \(http.statusCode)")
            }
        }

        let decoded: JSONRPCResponse<RemoteHeader>
        do {
            decoded = try JSONDecoder().decode(JSONRPCResponse<RemoteHeader>.self, from: data)
        } catch {
            throw ProbeError.unreachable("ответ не JSON-RPC: \(error.localizedDescription)")
        }
        if let rpcError = decoded.error {
            throw ProbeError.unreachable(rpcError.message ?? "JSON-RPC error \(rpcError.code ?? 0)")
        }
        guard let header = decoded.result?.Ok else {
            throw ProbeError.unreachable(decoded.result?.Err ?? "пустой ответ get_header")
        }
        return header
    }

    private static func validated(_ string: String) throws -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty else {
            throw ProbeError.invalidURL("нужен http(s)-адрес с хостом, например http://node:13413")
        }

        #if !targetEnvironment(simulator)
        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            throw ProbeError.localhostOnDevice
        }
        #endif

        return trimmed
    }
}
