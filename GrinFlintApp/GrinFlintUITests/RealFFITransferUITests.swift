import XCTest

#if GRINFFI
import UIKit

/// Живой UI-перевод с настоящим FFI.
///
/// Сценарий: приложение на симуляторе восстанавливает кошелёк A из seed через
/// онбординг (настоящий grin-wallet, локальная нода), затем через экран
/// отправки создаёт перевод на кошелёк B. B создаётся через FFI прямо в
/// тестовом процессе: он принимает Slatepack и возвращает ответ, который
/// вставляется в UI. Финализация идёт через UI, подтверждение проверяется
/// и в сети (B видит средства), и в UI (карточка перевода становится
/// подтверждённой).
///
/// Запуск требует macOS-симулятора и доступной floonet-ноды; env передаётся
/// через `TEST_RUNNER_*` (см. scripts/ui-e2e-macos.sh):
///   GRIN_E2E_SEED, GRIN_E2E_PASS, GRIN_E2E_NODE_URL,
///   GRIN_E2E_API_SECRET (опционально), GRIN_E2E_RESTORE_HEIGHT (опционально).
/// Без seed тест пропускается, поэтому обычный CI не требует ноды и средств.
final class RealFFITransferUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let seed = env["GRIN_E2E_SEED"], !seed.isEmpty else {
            throw XCTSkip("нет GRIN_E2E_SEED — живой UI-перевод с FFI не запускается")
        }
        _ = seed
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
    }

    func testTransferThroughUIWithRealFFI() throws {
        let seed = env["GRIN_E2E_SEED"]!
        let nodeURL = env["GRIN_E2E_NODE_URL"] ?? "http://127.0.0.1:13413"
        let apiSecret = (env["GRIN_E2E_API_SECRET"]?.isEmpty == false)
            ? env["GRIN_E2E_API_SECRET"] : nil
        let restoreHeight = (env["GRIN_E2E_RESTORE_HEIGHT"]?.isEmpty == false)
            ? env["GRIN_E2E_RESTORE_HEIGHT"] : nil

        // Получатель: отдельный кошелёк через тот же FFI, но в тестовом процессе.
        let recipient = try RecipientWallet(nodeURL: nodeURL, apiSecret: apiSecret)
        addTeardownBlock { recipient.destroy() }

        app.launch()

        // 1) Онбординг должен быть чистым: приложение устанавливают заново.
        let restoreButton = app.buttons["Восстановить из seed-фразы"]
        guard restoreButton.waitForExistence(timeout: 30) else {
            XCTFail(
                "онбординг не появился. Перед прогоном удалите приложение с симулятора: "
                    + "xcrun simctl uninstall booted com.dan.grinflint"
            )
            return
        }
        restoreButton.tap()

        // 2) Seed-фраза и (если задана) высота восстановления.
        let seedEditor = app.textViews["restore.seed"]
        XCTAssertTrue(seedEditor.waitForExistence(timeout: 10), "нет поля seed-фразы")
        seedEditor.tap()
        seedEditor.typeText(seed)

        if let restoreHeight {
            let heightField = app.textFields["restore.height"]
            XCTAssertTrue(heightField.waitForExistence(timeout: 10), "нет поля высоты")
            heightField.tap()
            heightField.typeText(restoreHeight)
        }

        app.buttons["Восстановить"].tap()

        // 3) Восстановление и скан — настоящий FFI, может занять минуты.
        XCTAssertTrue(
            app.staticTexts["Общий баланс"].waitForExistence(timeout: 900),
            "кошелёк не открылся после восстановления (проверьте ноду и seed)"
        )

        // 4) Отправка через UI.
        app.buttons["portfolio.send"].tap()
        let destination = app.textFields["send.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 15), "экран отправки не открылся")
        destination.tap()
        destination.typeText(recipient.address)

        let amount = app.textFields["send.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10), "нет поля суммы")
        amount.tap()
        amount.typeText("0.001")

        app.buttons["Создать транзакцию"].tap()
        XCTAssertTrue(
            app.staticTexts["Транзакция создана"].waitForExistence(timeout: 180),
            "FFI не создал транзакцию (проверьте баланс и ноду)"
        )

        // 5) Забираем Slatepack из UI и отвечаем кошельком B.
        let request = try slatepackFromUI()
        let response = try recipient.receive(request)

        // 6) Вставляем ответ и завершаем перевод через UI.
        let editor = app.textViews["send.response"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "нет поля ответного Slatepack")
        editor.tap()
        UIPasteboard.general.string = response
        editor.press(forDuration: 1.2)
        let paste = app.menuItems["Вставить"]
        if paste.waitForExistence(timeout: 5) {
            paste.tap()
        } else {
            editor.typeText(response)
        }

        app.buttons["Завершить перевод"].tap()
        XCTAssertTrue(
            app.staticTexts["Перевод завершён"].waitForExistence(timeout: 240),
            "финализация через FFI не прошла"
        )

        // 7) Подтверждение в сети: B видит средства после скана ноды.
        XCTAssertTrue(
            try recipient.waitForSpendable(atLeast: 1_000_000, timeout: 600),
            "получатель не увидел подтверждение за 10 минут"
        )

        // 8) UI обновляется до подтверждённого состояния.
        app.buttons["Готово"].tap()
        let pending = app.buttons["pending.operation"]
        let refresh = app.buttons["portfolio.refresh"]
        let deadline = Date().addingTimeInterval(600)
        while pending.exists && Date() < deadline {
            if refresh.isHittable {
                refresh.tap()
            }
            Thread.sleep(forTimeInterval: 5)
        }
        XCTAssertFalse(pending.exists, "UI не отметил перевод подтверждённым за 10 минут")
    }

    /// Slatepack из UI: обычно доступен как текст; запасной путь — кнопка копирования.
    private func slatepackFromUI() throws -> String {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "BEGINSLATEPACK")
        let text = app.staticTexts.matching(predicate).firstMatch
        if text.waitForExistence(timeout: 15) {
            let value = text.label
            if value.hasPrefix("BEGINSLATEPACK") {
                return value
            }
        }

        let copy = app.buttons["Копировать"].firstMatch
        if copy.waitForExistence(timeout: 5) {
            copy.tap()
            if let value = UIPasteboard.general.string, value.hasPrefix("BEGINSLATEPACK") {
                return value
            }
        }
        throw TestFFIError.message("не удалось получить Slatepack из UI")
    }
}

// MARK: - Кошелёк-получатель через реальный FFI

private enum TestFFIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

private enum TestFFI {
    static func error() -> String {
        guard let pointer = grin_last_error() else { return "нет ошибки" }
        return String(cString: pointer)
    }

    static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { grin_string_free(pointer) }
        return String(cString: pointer)
    }

    static func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Второй кошелёк (получатель) в тестовом процессе: тот же grin-wallet FFI,
/// что и в приложении, но отдельный каталог и seed.
private final class RecipientWallet {
    private var handle: OpaquePointer?
    private let password = "uitest-recipient-password"
    let address: String

    init(nodeURL: String, apiSecret: String?) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-recipient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        handle = grin_wallet_create(dir.path, nodeURL, "floonet", apiSecret)
        guard handle != nil else {
            throw TestFFIError.message("create: \(TestFFI.error())")
        }

        guard TestFFI.take(
            grin_wallet_create_seed_at(handle, password, 24, nil, 0)
        ) != nil else {
            throw TestFFIError.message("create_seed: \(TestFFI.error())")
        }

        guard let opened = TestFFI.take(grin_wallet_open(handle, password)),
              let json = TestFFI.json(opened),
              let address = json["address"] as? String else {
            throw TestFFIError.message("open: \(TestFFI.error())")
        }
        self.address = address
    }

    func receive(_ slatepack: String) throws -> String {
        guard let text = TestFFI.take(grin_wallet_receive(handle, slatepack)),
              let json = TestFFI.json(text),
              let response = json["slatepack"] as? String else {
            throw TestFFIError.message("receive: \(TestFFI.error())")
        }
        return response
    }

    func spendable() throws -> UInt64 {
        guard let text = TestFFI.take(grin_wallet_balance(handle, 1)),
              let json = TestFFI.json(text),
              let value = json["spendable"] as? NSNumber else {
            throw TestFFIError.message("balance: \(TestFFI.error())")
        }
        return value.uint64Value
    }

    func waitForSpendable(atLeast nano: UInt64, timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = try? spendable(), value >= nano {
                return true
            }
            Thread.sleep(forTimeInterval: 5)
        } while Date() < deadline
        return false
    }

    func destroy() {
        if let handle {
            grin_wallet_destroy(handle)
            self.handle = nil
        }
    }

    deinit { destroy() }
}
#endif
