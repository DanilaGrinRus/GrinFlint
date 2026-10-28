import XCTest

/// Проверка навигации: тапы по основным экранам в симуляторе.
///
/// Запускается с `-walletExists YES -simDemo`: приложение сразу открывает
/// основной UI с демо-сервисом, без онбординга и без сети.
final class NavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-walletExists", "YES", "-simDemo"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Падение с диагностикой: скриншот в xcresult и список элементов.
    private func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "failure"
        attachment.lifetime = .keepAlways
        add(attachment)
        let tabs = app.tabBars.buttons.allElementsBoundByIndex.map { $0.label }
        let bars = app.navigationBars.allElementsBoundByIndex.map { $0.identifier }
        XCTFail("\(message); вкладки=\(tabs); навбары=\(bars)", file: file, line: line)
    }

    private func waitPortfolio() {
        XCTAssertTrue(
            app.staticTexts["Общий баланс"].waitForExistence(timeout: 20),
            "портфель не открылся"
        )
    }

    /// Тап по вкладке с проверкой, что она действительно выбралась.
    private func selectTab(index: Int, title: String) {
        let tab = app.tabBars.buttons.element(boundBy: index)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "нет вкладки \(title)")
        XCTAssertEqual(tab.label, title, "подпись вкладки \(index) не «\(title)»")
        tab.tap()
        if !tab.isSelected {
            // Иногда первый тап уходит мимо — добиваем по координатам.
            tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        guard tab.isSelected else {
            // Иерархия в лог: видно, что перекрывает таб-бар.
            print("TAB DEBUG: \(app.debugDescription)")
            fail("вкладка «\(title)» не выбралась")
            return
        }
    }

    func testPortfolioAndTabs() {
        waitPortfolio()

        selectTab(index: 1, title: "Транзакции")
        XCTAssertTrue(
            app.navigationBars["Транзакции"].waitForExistence(timeout: 10),
            "экран «Транзакции» не открылся"
        )

        selectTab(index: 2, title: "Настройки")
        XCTAssertTrue(
            app.navigationBars["Настройки"].waitForExistence(timeout: 10),
            "экран «Настройки» не открылся"
        )

        selectTab(index: 0, title: "Портфель")
        XCTAssertTrue(
            app.staticTexts["Общий баланс"].waitForExistence(timeout: 10),
            "не вернулись на портфель"
        )
    }

    func testSendAndReceiveScreens() {
        waitPortfolio()

        // Отправка.
        app.buttons["portfolio.send"].tap()
        XCTAssertTrue(
            app.navigationBars["Отправить GRIN"].waitForExistence(timeout: 10),
            "экран отправки не открылся"
        )
        XCTAssertTrue(app.buttons["Создать транзакцию"].exists, "нет кнопки создания транзакции")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Общий баланс"].waitForExistence(timeout: 10),
            "не вернулись с экрана отправки"
        )

        // Приём.
        app.buttons["portfolio.receive"].tap()
        XCTAssertTrue(
            app.navigationBars["Получить GRIN"].waitForExistence(timeout: 10),
            "экран приёма не открылся"
        )
        XCTAssertTrue(app.buttons["Принять и зачислить"].exists, "нет кнопки приёма")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'grin1'")).firstMatch
                .waitForExistence(timeout: 5),
            "на экране приёма нет адреса"
        )
    }

    /// Ссылка `grinslate://` открывает лист приёма с подставленным Slatepack.
    func testIncomingSlatepackSheet() {
        app.terminate()
        app.launchArguments = [
            "-walletExists", "YES", "-simDemo",
            "-simIncoming", "BEGINSLATEPACK.test"
        ]
        app.launch()
        XCTAssertTrue(
            app.navigationBars["Получить GRIN"].waitForExistence(timeout: 20),
            "лист приёма по ссылке не открылся"
        )
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "нет поля для Slatepack")
        XCTAssertTrue(
            (editor.value as? String)?.contains("BEGINSLATEPACK") == true,
            "в поле нет текста из ссылки"
        )
    }
}
