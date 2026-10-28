import XCTest
@testable import GrinFlint

/// Сообщения об ошибках должны объяснять, что повторная подпись не создаётся.
/// Проверка не зависит от языка: хост-приложение в CI запускается на английском.
final class WalletErrorTests: XCTestCase {
    func testPendingOperationMessageExplainsNoResigning() {
        let message = WalletError
            .pendingOperationExists("details")
            .localizedDescription
        let lower = message.lowercased()

        XCTAssertTrue(
            lower.contains("unfinished transfer") || lower.contains("незавершённый перевод"),
            message
        )
        XCTAssertTrue(
            lower.contains("no re-signing") || lower.contains("повторная подпись"),
            message
        )
        XCTAssertTrue(message.contains("details"), message)
    }
}