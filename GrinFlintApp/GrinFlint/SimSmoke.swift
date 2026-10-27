import Foundation
import SwiftUI

/// Самопроверка на симуляторе для CI.
///
/// Приложение запускается с аргументом `-SimSmoke` и вместо обычного UI
/// прогоняет реальный стек: Keychain → grin-wallet через FFI → создание seed
/// (24 слова) → open (slatepack-адрес) → refresh против ноды, если она задана
/// в `GRINFLINT_SMOKE_NODE` → восстановление из той же фразы в отдельном
/// каталоге и сверка адреса. Итог пишется в `Documents/sim-smoke.json`;
/// job читает файл и падает, если `ok` не `true`.
///
/// Секреты в отчёт не попадают: seed-фраза и пароль не пишутся.
enum SimSmoke {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-SimSmoke")
    }

    static var resultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sim-smoke.json")
    }

    static func run() async {
        let report = SmokeReport()
        let started = Date()

        #if GRINFFI
        do {
            try await runFFI(report)
            report.set("ok", true)
        } catch {
            report.set("ok", false)
            report.set("error", String(describing: error))
        }
        #else
        report.set("ok", false)
        report.set("error", "сборка без GRINFFI: проверять нечего")
        #endif

        report.set("elapsed_ms", Int(Date().timeIntervalSince(started) * 1000))
        write(report.values)
    }

    #if GRINFFI
    private static func runFFI(_ report: SmokeReport) async throws {
        if let node = ProcessInfo.processInfo.environment["GRINFLINT_SMOKE_NODE"],
           !node.isEmpty {
            WalletFactory.nodeURL = node
        }
        report.set("node", WalletFactory.nodeURL)
        report.set("chain", WalletFactory.network.rawValue)

        // Keychain: пароль создаётся при первом запуске и переиспользуется.
        let password = try KeychainStore.loadOrCreatePassword()
        report.set("keychain_password", password.count >= 32)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dataDir = documents.appendingPathComponent("grin-wallet", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let service = try GrinWalletFFIService(
            dataDir: dataDir.path,
            nodeURL: WalletFactory.nodeURL,
            chain: WalletFactory.network == .mainnet ? .mainnet : .floonet,
            password: password
        )
        report.set("backend", service.backendName)
        report.set("demo", service.isDemo)

        let mnemonic = try await service.createWallet(mnemonicLength: 24)
        report.set("mnemonic_words", mnemonic.split(whereSeparator: { $0.isWhitespace }).count)

        try await service.open()
        let address = await service.slatepackAddress
        report.set("address", address)
        guard !address.isEmpty else { throw SimSmokeError.emptyAddress }

        do {
            try await service.refresh()
            report.set("refresh", "ok")
        } catch {
            report.set("refresh", "error: \(error.localizedDescription)")
        }

        let balance = await service.balance
        report.set("spendable_ngrin", NSDecimalNumber(decimal: balance.spendable).stringValue)
        report.set("awaiting_ngrin", NSDecimalNumber(decimal: balance.awaiting).stringValue)
        let txs = await service.transactions
        report.set("txs", txs.count)

        // Восстановление из той же фразы в другом каталоге: адрес обязан совпасть.
        let restoreDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-smoke-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: restoreDir) }

        let restored = try GrinWalletFFIService(
            dataDir: restoreDir.path,
            nodeURL: WalletFactory.nodeURL,
            chain: WalletFactory.network == .mainnet ? .mainnet : .floonet,
            password: password
        )
        try await restored.restore(mnemonic: mnemonic)
        try await restored.open()
        let restoredAddress = await restored.slatepackAddress
        report.set("restore_address_matches", restoredAddress == address)
        guard restoredAddress == address else { throw SimSmokeError.addressMismatch }
    }
    #endif

    private static func write(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: resultURL, options: .atomic)
        // Для `simctl launch --console`: одна строка с итогом, без секретов.
        print("SIM_SMOKE: " + (String(data: data, encoding: .utf8) ?? "{}"))
    }

    /// Изменяемый отчёт без `inout` через точку приостановки.
    private final class SmokeReport {
        private(set) var values: [String: Any] = [:]

        func set(_ key: String, _ value: Any) {
            values[key] = value
        }
    }

    enum SimSmokeError: LocalizedError {
        case emptyAddress
        case addressMismatch

        var errorDescription: String? {
            switch self {
            case .emptyAddress:
                return "пустой slatepack-адрес после open"
            case .addressMismatch:
                return "адрес после восстановления не совпал с исходным"
            }
        }
    }
}

/// Экран самопроверки: тот же бинарник, но без обычного UI.
struct SimSmokeView: View {
    @State private var text = "Самопроверка выполняется…"
    @State private var finished = false

    var body: some View {
        VStack(spacing: 16) {
            if !finished {
                ProgressView().tint(Theme.accent)
            }
            Text(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background.ignoresSafeArea())
        .task {
            await SimSmoke.run()
            finished = true
            text = (try? String(contentsOf: SimSmoke.resultURL, encoding: .utf8))
                ?? "нет файла результата"
        }
    }
}
