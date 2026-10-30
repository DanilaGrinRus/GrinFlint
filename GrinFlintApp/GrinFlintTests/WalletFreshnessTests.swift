import XCTest
@testable import GrinFlint

/// Свежесть баланса: если нода ответила, но update_wallet_state не обновил
/// состояние, показываем stale, а не «свежий» ноль.
final class WalletFreshnessTests: XCTestCase {
    func testRefreshMarksFreshWhenNodeUpdated() async {
        let service = MockWalletService()
        service.balanceIsFresh = true
        let viewModel = WalletViewModel(service: service)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.balanceState.freshness, .fresh)
    }

    func testRefreshMarksStaleWhenNodeDidNotUpdate() async {
        let service = MockWalletService()
        service.balanceIsFresh = true
        let viewModel = WalletViewModel(service: service)
        await viewModel.refresh()
        XCTAssertEqual(viewModel.balanceState.freshness, .fresh)

        service.balanceIsFresh = false
        await viewModel.refresh()

        XCTAssertEqual(viewModel.balanceState.freshness, .stale)
        XCTAssertNotNil(viewModel.balanceState.lastError)
    }
}
