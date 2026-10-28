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
        // Симулятор в CI англоязычный: тесты проверяют русские тексты,
        // поэтому язык задаётся явно (английский проверяется отдельным тестом).
        app.launchArguments = [
            "-walletExists", "YES", "-simDemo",
            "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"
        ]
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
        guard app.staticTexts["Общий баланс"].waitForExistence(timeout: 20) else {
            // Дамп иерархии: видно, на каком языке интерфейс и что на экране.
            print("PORTFOLIO DEBUG: \(app.debugDescription)")
            fail("портфель не открылся")
            return
        }
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
        XCTAssertTrue(
            app.images["receive.qr"].waitForExistence(timeout: 10),
            "нет QR-кода адреса"
        )
    }

    /// Ссылка `grinslate://` открывает лист приёма с подставленным Slatepack.
    func testIncomingSlatepackSheet() {
        app.terminate()
        app.launchArguments = [
            "-walletExists", "YES", "-simDemo",
            "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
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

    /// Детали транзакции открываются из истории.
    func testTransactionDetail() {        waitPortfolio()
        selectTab(index: 1, title: "Транзакции")
        XCTAssertTrue(
            app.navigationBars["Транзакции"].waitForExistence(timeout: 10),
            "экран «Транзакции» не открылся"
        )

        let row = app.buttons.containing(.staticText, identifier: "Получено").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "нет строки транзакции")
        row.tap()
        XCTAssertTrue(
            app.navigationBars["Детали"].waitForExistence(timeout: 10),
            "детали транзакции не открылись"
        )
        XCTAssertTrue(app.staticTexts["Комиссия"].exists, "в деталях нет комиссии")
    }

    /// Адресная книга: добавить контакт и подставить его в отправке.
    func testAddressBook() {
        waitPortfolio()
        selectTab(index: 2, title: "Настройки")
        XCTAssertTrue(
            app.navigationBars["Настройки"].waitForExistence(timeout: 10),
            "экран «Настройки» не открылся"
        )

        // Строка «Адресная книга» в настройках ниже сгиба — прокручиваем.
        let bookLink = app.buttons["settings.addressBook"]
        for _ in 0..<4 where !(bookLink.exists && bookLink.isHittable) {
            app.swipeUp()
        }
        guard bookLink.waitForExistence(timeout: 5), bookLink.isHittable else {
            print("SETTINGS DEBUG: \(app.debugDescription)")
            fail("нет доступной строки «Адресная книга» в настройках")
            return
        }
        // Тап по подписи «Контакты»: надёжнее, чем центр кнопки.
        let bookText = app.staticTexts["Контакты"]
        if bookText.exists && bookText.isHittable {
            bookText.tap()
        } else {
            bookLink.tap()
        }
        guard app.navigationBars["Адресная книга"].waitForExistence(timeout: 10) else {
            print("BOOK DEBUG: \(app.debugDescription)")
            fail("адресная книга не открылась")
            return
        }

        app.buttons["contacts.add"].tap()
        let name = app.textFields["contact.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "нет поля имени")
        name.tap()
        name.typeText("Alice")
        let address = app.textFields["contact.address"]
        address.tap()
        address.typeText("grin1testaddress")
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(
            app.staticTexts["Alice"].waitForExistence(timeout: 10),
            "контакт не появился в списке"
        )

        // Назад в настройки, затем в отправку — контакт подставляет адрес.
        app.navigationBars.buttons.firstMatch.tap()
        selectTab(index: 0, title: "Портфель")
        app.buttons["portfolio.send"].tap()
        XCTAssertTrue(
            app.navigationBars["Отправить GRIN"].waitForExistence(timeout: 10),
            "экран отправки не открылся"
        )
        let contact = app.buttons["send.contact"].firstMatch
        XCTAssertTrue(contact.waitForExistence(timeout: 10), "нет контакта в отправке")
        contact.tap()
        XCTAssertTrue(
            (app.textFields["send.destination"].value as? String)?
                .contains("grin1testaddress") == true,
            "адрес из контакта не подставился"
        )
    }

    /// Английская локализация из Localizable.xcstrings.
    func testEnglishLocalization() {
        app.terminate()
        app.launchArguments = [
            "-walletExists", "YES", "-simDemo",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Total balance"].waitForExistence(timeout: 20),
            "английская локализация не подхватилась"
        )
        XCTAssertTrue(app.tabBars.buttons["Portfolio"].exists, "вкладки не переведены")

        // Строка с интерполяцией: формат-ключ должен совпасть с каталогом.
        app.buttons["portfolio.send"].tap()
        XCTAssertTrue(
            app.navigationBars["Send GRIN"].waitForExistence(timeout: 10),
            "экран отправки не переведён"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Available:'"))
                .firstMatch.waitForExistence(timeout: 10),
            "интерполированная строка «Доступно: …» не переведена"
        )
    }

    /// Блокировка: при отказе аутентификации экран остаётся закрытым.
    func testLockStaysClosedWhenAuthenticationFails() {
        app.terminate()
        app.launchArguments = [
            "-walletExists", "YES", "-simDemo",
            "-requireBiometrics", "YES",
            "-simBiometric", "deny",
            "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
        ]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Кошелёк заблокирован"].waitForExistence(timeout: 20),
            "экран блокировки не появился"
        )
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Разблокировать'"))
            .firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Кошелёк заблокирован"].exists,
            "замок снялся без успешного подтверждения"
        )
        XCTAssertTrue(
            app.staticTexts["lock.error"].waitForExistence(timeout: 5),
            "нет сообщения об отказе подтверждения"
        )
    }

    /// Блокировка: успешное подтверждение пускает в кошелёк.
    func testLockOpensAfterAuthentication() {
        app.terminate()
        app.launchArguments = [
            "-walletExists", "YES", "-simDemo",
            "-requireBiometrics", "YES",
            "-simBiometric", "allow",
            "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
        ]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Общий баланс"].waitForExistence(timeout: 20),
            "после подтверждения кошелёк не открылся"
        )
        XCTAssertFalse(
            app.staticTexts["Кошелёк заблокирован"].exists,
            "замок остался на экране"
        )
    }

    /// Незавершённый перевод переживает перезапуск приложения.
    func testPendingOperationSurvivesRestart() {
        app.terminate()
        app.launchArguments = [
            "-walletExists", "YES", "-simDemo", "-simResetState",
            "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
        ]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Общий баланс"].waitForExistence(timeout: 20),
            "портфель не открылся"
        )
        app.buttons["portfolio.send"].tap()
        XCTAssertTrue(
            app.navigationBars["Отправить GRIN"].waitForExistence(timeout: 10),
            "экран отправки не открылся"
        )
        let destination = app.textFields["send.destination"]
        destination.tap()
        destination.typeText("grin1testaddress")
        let amount = app.textFields["send.amount"]
        amount.tap()
        amount.typeText("1")
        app.buttons["Создать транзакцию"].tap()
        XCTAssertTrue(
            app.staticTexts["Транзакция создана"].waitForExistence(timeout: 15),
            "транзакция не создалась"
        )
        app.buttons["Готово"].tap()

        // Перезапуск без сброса состояния: этап перевода должен сохраниться.
        app.terminate()
        app.launchArguments = [
            "-walletExists", "YES", "-simDemo",
            "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
        ]
        app.launch()
        XCTAssertTrue(
            app.buttons["pending.operation"].waitForExistence(timeout: 20),
            "незавершённый перевод потерялся после перезапуска"
        )
        app.buttons["pending.operation"].tap()
        XCTAssertTrue(
            app.navigationBars["Незавершённый перевод"].waitForExistence(timeout: 10),
            "экран продолжения перевода не открылся"
        )
        XCTAssertTrue(
            app.buttons["Завершить перевод"].waitForExistence(timeout: 10),
            "нет действия завершения перевода"
        )
    }

    /// Сканер QR: в симуляторе камеры нет — показываем понятное сообщение.
    func testScannerFallback() {
        waitPortfolio()
        app.buttons["portfolio.send"].tap()
        XCTAssertTrue(
            app.navigationBars["Отправить GRIN"].waitForExistence(timeout: 10),
            "экран отправки не открылся"
        )
        app.buttons["send.scan"].tap()
        XCTAssertTrue(
            app.staticTexts["scanner.unavailable"].waitForExistence(timeout: 10),
            "нет сообщения о недоступной камере"
        )
        app.buttons["Отмена"].tap()
        XCTAssertTrue(
            app.navigationBars["Отправить GRIN"].waitForExistence(timeout: 10),
            "сканирование не закрылось"
        )
    }
}
