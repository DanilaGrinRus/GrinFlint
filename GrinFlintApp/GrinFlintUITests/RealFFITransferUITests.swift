import XCTest

#if GRINFFI
import UIKit

/// Живые UI-переводы с настоящим FFI.
///
/// Общий сценарий: приложение на симуляторе восстанавливает кошелёк A из seed
/// через онбординг (настоящий grin-wallet, floonet-нода), создаёт перевод на
/// кошелёк B. B создаётся через FFI прямо в тестовом процессе: принимает
/// Slatepack и возвращает ответ, который вставляется в UI. Финализация идёт
/// через UI, подтверждение проверяется и в сети (B видит средства), и в UI.
///
/// `testRepostAfterPostFailureThroughUI` дополнительно требует прокси
/// (`GRIN_E2E_PROXY_URL`), который валит первый broadcast `push_transaction`:
/// finalize подписывает и сохраняет Slate, post получает настоящую ошибку,
/// после чего публикация повторяется кнопкой «Опубликовать снова».
///
/// Env передаётся через `TEST_RUNNER_*` (см. scripts/ui-e2e-macos.sh):
///   GRIN_E2E_SEED, GRIN_E2E_NODE_URL, GRIN_E2E_API_SECRET (опц.),
///   GRIN_E2E_RESTORE_HEIGHT (опц.), GRIN_E2E_PROXY_URL (для repost-теста).
/// Без seed тесты пропускаются: обычный CI не требует ноды и средств.
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
    }

    // MARK: - Тесты

    func testTransferThroughUIWithRealFFI() throws {
        let ctx = try startTransfer(nodeURLOverride: env["GRIN_E2E_NODE_URL"])
        let response = try ctx.recipient.receive(ctx.request)
        try pasteResponse(response)

        app.buttons["Завершить перевод"].tap()
        let finished = app.staticTexts["Перевод завершён"]
        let finishAlert = app.alerts["Не удалось завершить перевод"]
        let deadline = Date().addingTimeInterval(240)
        var alertText: String?
        while Date() < deadline {
            if finished.exists { break }
            if finishAlert.exists {
                alertText = finishAlert.staticTexts.allElementsBoundByIndex
                    .map(\.label)
                    .joined(separator: " | ")
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(
            finished.exists,
            alertText.map { "финализация через FFI не прошла: \($0)" }
                ?? "финализация через FFI не прошла"
        )
        XCTAssertTrue(
            try ctx.recipient.waitForSpendable(atLeast: 1_000_000, timeout: 600),
            "получатель не увидел подтверждение за 10 минут"
        )
        try closeTransferSheetAndWaitConfirmed()
    }

    /// Живой сбой публикации → повтор через UI без новой подписи.
    func testRepostAfterPostFailureThroughUI() throws {
        guard let proxy = env["GRIN_E2E_PROXY_URL"], !proxy.isEmpty else {
            throw XCTSkip("нет GRIN_E2E_PROXY_URL — живой сбой публикации не создаётся")
        }
        let ctx = try startTransfer(nodeURLOverride: proxy)
        let response = try ctx.recipient.receive(ctx.request)
        try pasteResponse(response)

        // 1) finalize подписывает и сохраняет Slate, но post упирается в 500 прокси.
        app.buttons["Завершить перевод"].tap()
        let alert = app.alerts["Не удалось завершить перевод"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: 180),
            "post не упал: прокси не перехватил push_transaction?"
        )
        alert.buttons["OK"].tap()

        // 2) Закрываем лист; в журнале операция на стадии «подписана».
        try tapButton(scrolling: "Готово")
        let card = app.buttons["pending.operation"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "нет карточки незавершённого перевода")
        card.tap()
        XCTAssertTrue(
            app.staticTexts["Транзакция подписана"].waitForExistence(timeout: 15),
            "журнал не остался на стадии finalized"
        )

        // 3) Повторная публикация без новой подписи.
        let repost = app.buttons["pending.repost"]
        XCTAssertTrue(repost.waitForExistence(timeout: 10), "нет кнопки «Опубликовать снова»")
        XCTAssertTrue(repost.isHittable, "кнопка повтора недоступна")
        repost.tap()
        XCTAssertTrue(
            app.staticTexts["Опубликована в сети"].waitForExistence(timeout: 180),
            "repost через UI не прошёл"
        )

        // 4) Подтверждение в сети и в UI.
        XCTAssertTrue(
            try ctx.recipient.waitForSpendable(atLeast: 1_000_000, timeout: 600),
            "получатель не увидел подтверждение после repost за 10 минут"
        )
        let deadline = Date().addingTimeInterval(600)
        while app.buttons["pending.operation"].exists && Date() < deadline {
            if app.buttons["pending.refresh"].exists, app.buttons["pending.refresh"].isHittable {
                app.buttons["pending.refresh"].tap()
            }
            Thread.sleep(forTimeInterval: 5)
        }
        XCTAssertFalse(app.buttons["pending.operation"].exists, "UI не отметил перевод подтверждённым")
    }

    // MARK: - Общий сценарий

    private struct TransferContext {
        let recipient: RecipientWallet
        let request: String
    }

    private func startTransfer(nodeURLOverride: String?) throws -> TransferContext {
        let seed = env["GRIN_E2E_SEED"]!
        let nodeURL = env["GRIN_E2E_NODE_URL"] ?? "http://127.0.0.1:13413"
        let apiSecret = (env["GRIN_E2E_API_SECRET"]?.isEmpty == false)
            ? env["GRIN_E2E_API_SECRET"] : nil
        let restoreHeight = (env["GRIN_E2E_RESTORE_HEIGHT"]?.isEmpty == false)
            ? env["GRIN_E2E_RESTORE_HEIGHT"] : nil

        let recipient = try RecipientWallet(nodeURL: nodeURL, apiSecret: apiSecret)
        addTeardownBlock { recipient.destroy() }

        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        if let nodeURLOverride {
            // UserDefaults читает аргументы запуска: кошелёк ходит через прокси.
            app.launchArguments += ["-nodeURL", nodeURLOverride]
        }
        app.launch()

        // Онбординг должен быть чистым: приложение устанавливают заново.
        let restoreButton = app.buttons["Восстановить из seed-фразы"]
        guard restoreButton.waitForExistence(timeout: 30) else {
            throw TestFFIError.message(
                "онбординг не появился. Перед прогоном удалите приложение: "
                    + "xcrun simctl uninstall booted com.dan.grinflint"
            )
        }
        restoreButton.tap()

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

        XCTAssertTrue(
            app.staticTexts["Общий баланс"].waitForExistence(timeout: 900),
            "кошелёк не открылся после восстановления (проверьте ноду и seed)"
        )

        // Отправка.
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
        let request = try slatepackFromUI()
        return TransferContext(recipient: recipient, request: request)
    }

    private func pasteResponse(_ response: String) throws {
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
    }

    /// Закрывает лист перевода и ждёт, пока карточка операции исчезнет.
    private func closeTransferSheetAndWaitConfirmed() throws {
        try tapButton(scrolling: "Готово")
        let pending = app.buttons["pending.operation"]
        let refresh = app.buttons["portfolio.refresh"]
        let deadline = Date().addingTimeInterval(600)
        while pending.exists && Date() < deadline {
            if refresh.isHittable { refresh.tap() }
            Thread.sleep(forTimeInterval: 5)
        }
        XCTAssertFalse(pending.exists, "UI не отметил перевод подтверждённым за 10 минут")
    }

    private func tapButton(scrolling label: String) throws {
        let button = app.buttons[label]
        for _ in 0..<4 where !(button.exists && button.isHittable) {
            app.swipeUp()
        }
        guard button.waitForExistence(timeout: 10), button.isHittable else {
            throw TestFFIError.message("кнопка «\(label)» недоступна")
        }
        button.tap()
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
