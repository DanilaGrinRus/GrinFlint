import XCTest
@testable import GrinFlint

/// Юнит-тесты журнала незавершённых переводов: этап операции не должен
/// теряться после перезапуска, а ожидающая отправка — дублироваться.
final class PendingOperationsStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grinflint-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sendOperation(amount: String = "1", created: Date = Date()) -> PendingOperation {
        PendingOperation(
            id: UUID(),
            kind: .send,
            stage: .awaitingResponse,
            slatepack: "BEGINSLATEPACK.send",
            destination: "grin1receiver",
            amount: amount,
            fee: "0.003",
            txID: UUID().uuidString,
            createdAt: created,
            lastError: nil
        )
    }

    private func receiveOperation(created: Date = Date()) -> PendingOperation {
        PendingOperation(
            id: UUID(),
            kind: .receive,
            stage: .responseReady,
            slatepack: "BEGINSLATEPACK.reply",
            destination: nil,
            amount: nil,
            fee: nil,
            txID: nil,
            createdAt: created,
            lastError: nil
        )
    }

    func testOperationSurvivesStoreRecreation() {
        let operation = sendOperation()
        let store = PendingOperationsStore(directory: directory)
        store.upsert(operation)

        // Новый экземпляр = холодный старт приложения.
        let reopened = PendingOperationsStore(directory: directory)
        XCTAssertEqual(reopened.operations.count, 1)
        XCTAssertEqual(reopened.latest?.id, operation.id)
        XCTAssertEqual(reopened.latest?.slatepack, operation.slatepack)
        XCTAssertEqual(reopened.latest?.stage, .awaitingResponse)
    }

    func testAwaitingSendPrefersLatestUnfinishedSend() {
        let store = PendingOperationsStore(directory: directory)
        let old = sendOperation(created: Date().addingTimeInterval(-60))
        let recent = sendOperation(created: Date())
        let received = receiveOperation(created: Date().addingTimeInterval(30))
        store.upsert(old)
        store.upsert(received)
        store.upsert(recent)

        XCTAssertEqual(store.awaitingSend?.id, recent.id)
        XCTAssertEqual(store.latest?.id, received.id)
    }

    func testCompletedReceiveIsNotAwaitingSend() {
        let store = PendingOperationsStore(directory: directory)
        store.upsert(receiveOperation())
        XCTAssertNil(store.awaitingSend)
        XCTAssertNotNil(store.latest)
    }

    func testRemoveDropsOperation() {
        let store = PendingOperationsStore(directory: directory)
        let operation = sendOperation()
        store.upsert(operation)
        store.remove(id: operation.id)

        XCTAssertTrue(store.operations.isEmpty)
        XCTAssertNil(PendingOperationsStore(directory: directory).latest)
    }

    func testLookupByTransactionID() {
        let store = PendingOperationsStore(directory: directory)
        let operation = sendOperation()
        store.upsert(operation)

        XCTAssertEqual(store.operation(txID: operation.txID ?? "")?.id, operation.id)
        XCTAssertNil(store.operation(txID: "unknown"))
    }

    func testCorruptedFileYieldsEmptyJournal() throws {
        let file = directory.appendingPathComponent("pending-operations.json")
        try Data("не json".utf8).write(to: file)

        let store = PendingOperationsStore(directory: directory)
        XCTAssertTrue(store.operations.isEmpty)
        XCTAssertNil(store.latest)
    }

    func testCodableRoundTripKeepsAllFields() throws {
        let operation = sendOperation()
        let data = try JSONEncoder().encode(operation)
        let decoded = try JSONDecoder().decode(PendingOperation.self, from: data)
        XCTAssertEqual(decoded, operation)
    }

    func testStageTitlesAreUserFacing() {
        XCTAssertFalse(PendingOperationStage.awaitingResponse.title.isEmpty)
        XCTAssertFalse(PendingOperationStage.responseReady.title.isEmpty)
        XCTAssertNotEqual(
            PendingOperationStage.awaitingResponse.title,
            PendingOperationStage.responseReady.title
        )
    }
}
