import XCTest
@testable import GrinFlint

/// Сообщения об ошибках должны объяснять, что повторная подпись не создаётся.
final class WalletErrorTests: XCTestCase {
    func testPendingOperationMessageExplainsNoResigning() {
        let message = WalletError
            .pendingOperationExists("Ждём ответ получателя")
            .localizedDescription
        XCTAssertTrue(message.contains("езавершённый перевод"), message)
        XCTAssertTrue(message.contains("повторная подпись"), message)
        XCTAssertTrue(message.contains("Ждём ответ получателя"), message)
    }
}
