#if GRINFFI
import Foundation

/// Тонкая обёртка над C API (grin_wallet_ffi.h).
/// Низкий уровень: raw-указатели, JSON-парсинг, освобождение строк.
enum GrinFFIError: LocalizedError {
    case nullPointer
    case badJSON(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .nullPointer: return "FFI: NULL-указатель"
        case .badJSON(let s): return "FFI: некорректный JSON: \(s.prefix(200))"
        case .api(let m): return m
        }
    }
}

final class GrinWalletHandle {
    private(set) var raw: OpaquePointer?

    init(dataDir: String, nodeURL: String, chain: String, apiSecret: String = "") throws {
        raw = grin_wallet_create(dataDir, nodeURL, chain, apiSecret.isEmpty ? nil : apiSecret)
        if raw == nil { throw GrinFFIError.api(GrinFFI.lastError()) }
    }

    deinit { close() }

    func close() {
        if let raw {
            grin_wallet_destroy(raw)
            self.raw = nil
        }
    }
}

enum GrinFFI {
    static func lastError() -> String {
        String(cString: grin_last_error())
    }

    /// Вызов функции, возвращающей JSON-строку; освобождает её после парсинга.
    static func call<T: Decodable>(_ body: (GrinWalletHandle) -> UnsafeMutablePointer<CChar>?,
                                   handle: GrinWalletHandle,
                                   as type: T.Type) throws -> T {
        guard let ptr = body(handle) else {
            throw GrinFFIError.api(lastError())
        }
        defer { grin_string_free(ptr) }
        let string = String(cString: ptr)
        guard let data = string.data(using: .utf8) else {
            throw GrinFFIError.badJSON(string)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GrinFFIError.badJSON(string)
        }
    }

    /// Вызов функции, возвращающих статус (0/-1).
    static func callStatus(_ body: (GrinWalletHandle) -> Int32, handle: GrinWalletHandle) throws {
        if body(handle) != 0 {
            throw GrinFFIError.api(lastError())
        }
    }

    /// Вызов функции без handle (например, проверка ноды).
    static func callStandalone<T: Decodable>(
        _ body: () -> UnsafeMutablePointer<CChar>?,
        as type: T.Type
    ) throws -> T {
        guard let ptr = body() else {
            throw GrinFFIError.api(lastError())
        }
        defer { grin_string_free(ptr) }
        let string = String(cString: ptr)
        guard let data = string.data(using: .utf8) else {
            throw GrinFFIError.badJSON(string)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GrinFFIError.badJSON(string)
        }
    }
}

// MARK: - DTO из JSON ответов FFI

struct GrinAddressResult: Decodable {
    let address: String
}

struct GrinMnemonicResult: Decodable {
    let mnemonic: String
}

struct GrinBalanceResult: Decodable {
    let spendable: UInt64
    let awaiting: UInt64
    let locked: UInt64
    let total: UInt64
}

struct GrinTxItem: Decodable {
    let id: UInt32
    let type: String
    let confirmed: Bool
    let amount: UInt64
    let fee: UInt64?
    let message: String?
    let creation_ts: String?
    let slate_id: String?
}

struct GrinTxsResult: Decodable {
    let txs: [GrinTxItem]
}

struct GrinSendResult: Decodable {
    let slatepack: String
    let slate_id: String
    let fee: UInt64
}

/// Оценка комиссии до подписания: `fee` и итоговое списание `total`.
struct GrinFeeEstimate: Decodable {
    let fee: UInt64
    let total: UInt64
}

struct GrinReceiveResult: Decodable {
    let slatepack: String
}

struct GrinNodeChainResult: Decodable {
    let chain: String
    let hash: String
    let height: UInt64
}

/// Genesis-хеш сети кошелька (для проверки совместимости ноды).
struct GrinChainGenesis: Decodable {
    let chain: String
    let hash: String
}

/// Результат точного разбора суммы общим контрактом.
struct GrinAmountResult: Decodable {
    let nano: UInt64
    let display: String
}
#endif
