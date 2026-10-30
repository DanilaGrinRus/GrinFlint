import XCTest
@testable import GrinFlint

/// Проверка seed → адрес на реальном FFI (без ноды): именно на этом
/// строится запрет открывать чужой кошелёк при ошибке восстановления.
final class FFIRestoreVerificationTests: XCTestCase {
    private func makeService(
        _ name: String
    ) throws -> (GrinWalletFFIService, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grinflint-ffi-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = try GrinWalletFFIService(
            dataDir: dir.path,
            nodeURL: "http://127.0.0.1:1",
            chain: .floonet,
            password: "test-pass"
        )
        return (service, dir)
    }

    func testAddressForMnemonicMatchesOpenedWallet() async throws {
        let (service, dir) = try makeService("address")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mnemonic = try await service.createWallet(mnemonicLength: 12)
        let expected = try await service.address(forMnemonic: mnemonic)
        try await service.open()
        let actual = await service.slatepackAddress
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.hasPrefix("tgrin1"))
    }

    func testDifferentSeedsHaveDifferentAddresses() async throws {
        let (first, firstDir) = try makeService("first")
        defer { try? FileManager.default.removeItem(at: firstDir) }
        let (second, secondDir) = try makeService("second")
        defer { try? FileManager.default.removeItem(at: secondDir) }

        let firstMnemonic = try await first.createWallet(mnemonicLength: 12)
        let secondMnemonic = try await second.createWallet(mnemonicLength: 12)
        let firstAddress = try await first.address(forMnemonic: firstMnemonic)
        let secondAddress = try await second.address(forMnemonic: secondMnemonic)
        XCTAssertNotEqual(firstAddress, secondAddress)
    }

    func testCorruptJournalBlocksNewSend() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grinflint-ffi-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a journal".utf8)
            .write(to: dir.appendingPathComponent("pending-operations.json"))

        let service = try GrinWalletFFIService(
            dataDir: dir.path,
            nodeURL: "http://127.0.0.1:1",
            chain: .floonet,
            password: "test-pass"
        )
        let warning = await service.journalWarning
        XCTAssertNotNil(warning)

        do {
            _ = try await service.prepareSend(destination: "tgrin1test", amountText: "1")
            XCTFail("перевод при повреждённом журнале должен быть запрещён")
        } catch {
            guard case WalletError.journalUnavailable = error else {
                XCTFail("ожидалась ошибка журнала, получено: \(error)")
                return
            }
        }
    }
}
