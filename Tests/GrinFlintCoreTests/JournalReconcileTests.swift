import XCTest
import Foundation
@testable import GrinFlintCore

/// Сверка журнала с backend после сбоя: подпись/публикация не должны
/// теряться, а «finalized» без подписи не должен предлагать repost.
final class JournalReconcileTests: XCTestCase {
    func testMissingTransactionKeepsJournal() {
        for stage in [PendingOperationStage.prepared, .requestSent, .finalized, .posted] {
            XCTAssertNil(
                JournalReconciler.stage(current: stage, status: .missing),
                "\(stage): отсутствие tx в backend не должно двигать стадию"
            )
        }
    }

    func testConfirmedAndCancelledWin() {
        let confirmed = TransferStatusSnapshot(
            found: true, confirmed: true, cancelled: false, hasRepost: true, slateState: "Standard3"
        )
        XCTAssertEqual(JournalReconciler.stage(current: .requestSent, status: confirmed), .confirmed)

        let cancelled = TransferStatusSnapshot(
            found: true, confirmed: false, cancelled: true, hasRepost: false, slateState: nil
        )
        XCTAssertEqual(JournalReconciler.stage(current: .requestSent, status: cancelled), .cancelled)
    }

    func testSignedSlateUpgradesRequestSentToFinalized() {
        let signed = TransferStatusSnapshot(
            found: true, confirmed: false, cancelled: false, hasRepost: true, slateState: "Standard3"
        )
        XCTAssertEqual(JournalReconciler.stage(current: .requestSent, status: signed), .finalized)
        XCTAssertEqual(JournalReconciler.stage(current: .prepared, status: signed), .finalized)
    }

    func testPostedStaysPostedUntilConfirmation() {
        let signed = TransferStatusSnapshot(
            found: true, confirmed: false, cancelled: false, hasRepost: true, slateState: "Standard3"
        )
        XCTAssertEqual(JournalReconciler.stage(current: .posted, status: signed), .posted)
    }

    func testFinalizedWithoutSignatureFallsBackToRequestSent() {
        let responseOnly = TransferStatusSnapshot(
            found: true, confirmed: false, cancelled: false, hasRepost: false, slateState: "Standard2"
        )
        XCTAssertEqual(JournalReconciler.stage(current: .finalized, status: responseOnly), .requestSent)
    }

    func testAwaitingFinalizeDoesNotMoveEarlyStages() {
        let responseOnly = TransferStatusSnapshot(
            found: true, confirmed: false, cancelled: false, hasRepost: false, slateState: "Standard2"
        )
        XCTAssertNil(JournalReconciler.stage(current: .requestSent, status: responseOnly))
        XCTAssertNil(JournalReconciler.stage(current: .prepared, status: responseOnly))
    }
}
