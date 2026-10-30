import XCTest
import Foundation
@testable import GrinFlintCore

/// Юнит-тесты журнала незавершённых переводов: этап операции не должен
/// теряться после перезапуска, а ожидающая отправка — дублироваться.
///
/// Запускаются без macOS: `swift test` (SwiftPM, Windows/Linux).
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

    private func sendOperation(
        stage: PendingOperationStage = .prepared,
        amount: String = "1",
        created: Date = Date()
    ) -> PendingOperation {
        PendingOperation(
            id: UUID(),
            kind: .send,
            stage: stage,
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
            stage: .prepared,
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
        let operation = sendOperation(stage: .requestSent)
        let store = PendingOperationsStore(directory: directory)
        store.upsert(operation)

        // Новый экземпляр = холодный старт приложения.
        let reopened = PendingOperationsStore(directory: directory)
        XCTAssertEqual(reopened.operations.count, 1)
        XCTAssertEqual(reopened.latest?.id, operation.id)
        XCTAssertEqual(reopened.latest?.slatepack, operation.slatepack)
        XCTAssertEqual(reopened.latest?.stage, .requestSent)
    }

    func testUnfinishedSendPrefersLatestUnfinishedSend() {
        let store = PendingOperationsStore(directory: directory)
        let old = sendOperation(created: Date().addingTimeInterval(-60))
        let recent = sendOperation(created: Date())
        let received = receiveOperation(created: Date().addingTimeInterval(30))
        store.upsert(old)
        store.upsert(received)
        store.upsert(recent)

        XCTAssertEqual(store.unfinishedSend?.id, recent.id)
        XCTAssertEqual(store.latest?.id, received.id)
    }

    func testPostedSendDoesNotBlockNewSend() {
        let store = PendingOperationsStore(directory: directory)
        store.upsert(sendOperation(stage: .posted))
        XCTAssertNil(store.unfinishedSend)
        // Опубликованная, но не подтверждённая операция остаётся активной.
        XCTAssertNotNil(store.active)
    }

    func testFinalizedSendStillBlocksNewSend() {
        let store = PendingOperationsStore(directory: directory)
        store.upsert(sendOperation(stage: .finalized))
        XCTAssertNotNil(store.unfinishedSend, "подписанная, но не опубликованная tx должна блокировать новую отправку")
    }

    func testCompletedReceiveIsNotAwaitingSend() {
        let store = PendingOperationsStore(directory: directory)
        store.upsert(receiveOperation())
        XCTAssertNil(store.unfinishedSend)
        XCTAssertNotNil(store.active)
    }

    func testTerminalStagesAreNotActive() {
        let store = PendingOperationsStore(directory: directory)
        store.upsert(sendOperation(stage: .confirmed))
        XCTAssertNil(store.active)
        XCTAssertNotNil(store.latest, "терминальная запись остаётся в журнале")

        store.upsert(sendOperation(stage: .cancelled))
        XCTAssertNil(store.active)
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
        XCTAssertEqual(store.operation(id: operation.id)?.id, operation.id)
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
        let operation = sendOperation(stage: .finalized)
        let data = try JSONEncoder().encode(operation)
        let decoded = try JSONDecoder().decode(PendingOperation.self, from: data)
        XCTAssertEqual(decoded, operation)
    }

    /// Записи прежних сборок (`awaitingResponse`/`responseReady`) читаются
    /// как prepared — старый журнал не теряется при обновлении приложения.
    func testLegacySendStageDecodesAsPrepared() throws {
        let data = try JSONEncoder().encode(sendOperation(stage: .prepared))
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"prepared\"", with: "\"awaitingResponse\"")
        let decoded = try JSONDecoder().decode(PendingOperation.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.stage, .prepared)
    }

    func testLegacyReceiveStageDecodesAsPrepared() throws {
        let data = try JSONEncoder().encode(receiveOperation())
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"prepared\"", with: "\"responseReady\"")
        let decoded = try JSONDecoder().decode(PendingOperation.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.stage, .prepared)
    }

    func testStageTitlesAndDetailsAreUserFacing() {
        for stage in PendingOperationStage.allCases {
            XCTAssertFalse(stage.title.isEmpty, "\(stage): пустой заголовок")
            XCTAssertFalse(stage.detail.isEmpty, "\(stage): пустое пояснение")
        }
        XCTAssertNotEqual(PendingOperationStage.prepared.title, PendingOperationStage.posted.title)
        XCTAssertTrue(PendingOperationStage.confirmed.isTerminal)
        XCTAssertTrue(PendingOperationStage.cancelled.isTerminal)
        XCTAssertFalse(PendingOperationStage.finalized.isTerminal)
        XCTAssertTrue(PendingOperationStage.finalized.blocksNewSend)
        XCTAssertFalse(PendingOperationStage.posted.blocksNewSend)
        XCTAssertTrue(PendingOperationStage.requestSent.acceptsResponse)
        XCTAssertFalse(PendingOperationStage.finalized.acceptsResponse)
    }

    func testSaveWritesBackup() {
        let store = PendingOperationsStore(directory: directory)
        store.upsert(sendOperation())
        let main = directory.appendingPathComponent("pending-operations.json")
        let backup = directory.appendingPathComponent("pending-operations.json.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: main.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertNil(store.errorDescription)
    }

    func testCorruptMainLoadsBackupAndReports() throws {
        let store = PendingOperationsStore(directory: directory)
        store.upsert(sendOperation())
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("pending-operations.json")
        )
        let reloaded = PendingOperationsStore(directory: directory)
        XCTAssertEqual(reloaded.operations.count, 1, "должна загрузиться резервная копия")
        XCTAssertNil(reloaded.loadError)
        XCTAssertNotNil(reloaded.recoveryWarning)
        XCTAssertFalse(reloaded.blocksNewSend, "после восстановления переводы разрешены")

        // Основной файл чинится сразу: следующий запуск без предупреждений.
        let repaired = PendingOperationsStore(directory: directory)
        XCTAssertNil(repaired.errorDescription)
        XCTAssertEqual(repaired.operations.count, 1)
    }

    func testCorruptMainAndBackupReportError() throws {
        let store = PendingOperationsStore(directory: directory)
        store.upsert(sendOperation())
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("pending-operations.json")
        )
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("pending-operations.json.bak")
        )
        let reloaded = PendingOperationsStore(directory: directory)
        XCTAssertTrue(reloaded.operations.isEmpty)
        XCTAssertNotNil(reloaded.loadError)
        XCTAssertNotNil(reloaded.errorDescription)
        XCTAssertTrue(reloaded.blocksNewSend)
    }

    func testSaveFailureIsReported() throws {
        let file = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let store = PendingOperationsStore(directory: file)
        store.upsert(sendOperation())
        XCTAssertEqual(store.operations.count, 1, "операция остаётся в памяти")
        XCTAssertNotNil(store.lastSaveError)
        XCTAssertNotNil(store.errorDescription)
        XCTAssertTrue(store.blocksNewSend)
    }
}

/// Форматирование и разбор сумм — чистая логика без FFI.
final class GrinFormatTests: XCTestCase {
    func testParseAcceptsCommaAndDot() {
        XCTAssertEqual(GrinFormat.parse("1,5"), Decimal(string: "1.5"))
        XCTAssertEqual(GrinFormat.parse("10.25"), Decimal(string: "10.25"))
    }

    func testParseRejectsZeroAndGarbage() {
        XCTAssertNil(GrinFormat.parse("0"))
        XCTAssertNil(GrinFormat.parse("-1"))
        XCTAssertNil(GrinFormat.parse("abc"))
        XCTAssertNil(GrinFormat.parse(""))
    }

    func testFormatsWithSuffixAndNineDigits() {
        XCTAssertEqual(
            GrinFormat.grin(Decimal(string: "1.5")!),
            "1.5 GRIN"
        )
        XCTAssertEqual(
            GrinFormat.grin(Decimal(string: "0.000000001")!),
            "0.000000001 GRIN"
        )
    }

    func testAmountForInputHasNoSuffixOrGrouping() {
        XCTAssertEqual(GrinFormat.amount(Decimal(string: "1234.5")!), "1234.5")
        XCTAssertEqual(GrinFormat.short(Decimal(string: "0.123456")!), "0.1235")
    }
}
