import Foundation

/// Кодировщик Bech32 (BIP-0173), используется для Slatepack-сообщений Grin
/// (HRP «grinslate»). Только кодирование — для чтения входящих Slatepack
/// в продакшене достаточно проверки префикса, полный декодер добавляется
/// вместе с интеграцией grin-wallet.
enum Bech32 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    static func encode(hrp: String, data: [UInt8], constant: UInt32 = 1) -> String {
        var combined = data
        combined.append(contentsOf: createChecksum(hrp: hrp, data: data, constant: constant))
        var result = hrp + "1"
        for value in combined {
            result.append(charset[Int(value)])
        }
        return result
    }

    private static func hrpExpand(_ hrp: String) -> [UInt32] {
        var result: [UInt32] = []
        for scalar in hrp.unicodeScalars {
            result.append(UInt32(scalar.value) >> 5)
        }
        result.append(0)
        for scalar in hrp.unicodeScalars {
            result.append(UInt32(scalar.value) & 31)
        }
        return result
    }

    private static func polymod(_ values: [UInt32]) -> UInt32 {
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(value)
            for i in 0..<5 where (top >> i) & 1 == 1 {
                chk ^= generators[i]
            }
        }
        return chk
    }

    private static func createChecksum(hrp: String, data: [UInt8], constant: UInt32) -> [UInt8] {
        var values = hrpExpand(hrp)
        values.append(contentsOf: data.map(UInt32.init))
        values.append(contentsOf: [0, 0, 0, 0, 0, 0])
        let mod = polymod(values) ^ constant
        var result: [UInt8] = []
        for i in 0..<6 {
            result.append(UInt8((mod >> UInt32(5 * (5 - i))) & 31))
        }
        return result
    }
}

/// Преобразование битовых групп (8-бит -> 5-бит для Bech32).
enum BitConverter {
    static func convertBits(_ data: [UInt8], from: UInt8, to: UInt8, pad: Bool = true) -> [UInt8] {
        var accumulator: UInt32 = 0
        var bits: UInt8 = 0
        var result: [UInt8] = []
        let maxValue: UInt32 = (1 << to) - 1
        for value in data {
            accumulator = (accumulator << from) | UInt32(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((accumulator >> bits) & maxValue))
            }
        }
        if pad && bits > 0 {
            result.append(UInt8((accumulator << (to - bits)) & maxValue))
        }
        return result
    }
}
