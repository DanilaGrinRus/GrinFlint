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

    func testPortfolioAndTabs() {
        XCTAssertTrue(
            app.staticTexts["Общий баланс"].waitForExistence(timeout: 20),
            "портфель не открылся"
        )

        app.tabBars.buttons["Транзакции"].tap()
        XCTAssertTrue(
            app.navigationBars["Транзакции"].waitForExistence(timeout: 10),
            "вкладка «Транзакции» не открылась"
        )

        app.tabBars.buttons["Настройки"].tap()
        XCTAssertTrue(
            app.navigationBars["Настройки"].waitForExistence(timeout: 10),
            "вкладка «Настройки» не открылась"
        )

        app.tabBars.buttons["Портфель"].tap()
        XCTAssertTrue(
            app.staticTexts["Общий баланс"].waitForExistence(timeout: 10),
            "не вернулись на портфель"
        )
    }

    func testSendAndReceiveScreens() {
        XCTAssertTrue(
            app.staticTexts["Общий баланс"].waitForExistence(timeout: 20),
            "портфель не открылся"
        )

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
}
