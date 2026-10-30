import XCTest
@testable import GrinFlintCore

/// Свежесть баланса: нули не выдаются за достоверные, устаревшие значения
/// сохраняются с явной пометкой.
final class BalanceStateTests: XCTestCase {
    private let funded = Balance(
        spendable: Decimal(string: "48.735")!,
        awaiting: 0,
        locked: 0
    )

    func testInitialStateIsUnknownNotZeroTruth() {
        let state = BalanceState.initial
        XCTAssertTrue(state.isUnknown)
        XCTAssertFalse(state.isStale)
        XCTAssertNil(state.lastUpdated)
        XCTAssertNil(state.lastError)
        // Нули есть, но они явно помечены как неизвестные.
        XCTAssertEqual(state.balance, .zero)
        XCTAssertFalse(state.freshnessText.isEmpty)
    }

    func testNodeUpdateMakesBalanceFresh() {
        var state = BalanceState.initial
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        state.updateFromNode(funded, at: now)

        XCTAssertEqual(state.freshness, .fresh)
        XCTAssertEqual(state.balance, funded)
        XCTAssertEqual(state.lastUpdated, now)
        XCTAssertNil(state.lastError)
        XCTAssertTrue(state.freshnessText.contains("Обновлено"))
    }

    func testFailureBeforeFirstSuccessStaysUnknown() {
        var state = BalanceState.initial
        state.fail("нода недоступна")

        XCTAssertTrue(state.isUnknown)
        XCTAssertEqual(state.lastError, "нода недоступна")
        XCTAssertNil(state.lastUpdated)
        XCTAssertTrue(state.freshnessText.contains("неизвестен"))
    }

    func testFailureAfterSuccessKeepsValuesAndMarksStale() {
        var state = BalanceState.initial
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        state.updateFromNode(funded, at: now)
        state.fail("нода недоступна")

        XCTAssertTrue(state.isStale)
        XCTAssertEqual(state.balance, funded, "прежние значения не обнуляются")
        XCTAssertEqual(state.lastUpdated, now, "время последнего успеха сохраняется")
        XCTAssertEqual(state.lastError, "нода недоступна")
        XCTAssertTrue(state.freshnessText.contains("Нет связи"))
    }

    func testRecoveryAfterFailureMakesFreshAgain() {
        var state = BalanceState.initial
        state.fail("нет сети")
        state.updateFromNode(funded)

        XCTAssertEqual(state.freshness, .fresh)
        XCTAssertNil(state.lastError)
    }

    func testLocalUpdateDoesNotInventFreshness() {
        var state = BalanceState.initial
        state.updateLocally(funded)
        XCTAssertTrue(state.isUnknown, "локальные значения не делают баланс проверенным")

        state.updateFromNode(funded)
        state.updateLocally(.zero)
        XCTAssertEqual(state.freshness, .fresh, "локальное списание не сбрасывает свежесть")
        XCTAssertEqual(state.balance, .zero)
    }
}
