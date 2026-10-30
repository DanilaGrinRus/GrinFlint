import Foundation

/// Снимок backend-состояния перевода по slate_id (ответ FFI
/// `grin_wallet_transfer_status`). Нужен, чтобы восстановить журнал после
/// сбоя: приложение могло не успеть записать стадию, а подпись уже есть.
struct TransferStatusSnapshot: Equatable {
    var found: Bool
    var confirmed: Bool
    var cancelled: Bool
    var hasRepost: Bool
    var slateState: String?

    static let missing = TransferStatusSnapshot(
        found: false,
        confirmed: false,
        cancelled: false,
        hasRepost: false,
        slateState: nil
    )

    /// Состояние подписи/публикации по данным grin-wallet:
    /// Standard3/Invoice3 — подписано, файл для repost может существовать.
    var isSignedOrPosted: Bool {
        hasRepost || slateState == "Standard3" || slateState == "Invoice3"
    }

    /// Ответ получателя уже есть, но подписи ещё нет.
    var isAwaitingFinalize: Bool {
        slateState == "Standard2" || slateState == "Invoice2"
    }
}

/// Чистое сопоставление backend-статуса и стадии журнала.
///
/// Правила:
/// - подтверждено/отменено — терминальное состояние backend важнее журнала;
/// - есть подписанный Slate (файл или Standard3) — finalized (если журнал уже
///   не записал posted);
/// - журнал говорит finalized, а backend подписи не видит — откатываем в
///   requestSent, чтобы можно было подписать заново, а не предлагать
///   несуществующий repost.
enum JournalReconciler {
    static func stage(
        current: PendingOperationStage,
        status: TransferStatusSnapshot
    ) -> PendingOperationStage? {
        guard status.found else { return nil }

        if status.cancelled { return .cancelled }
        if status.confirmed { return .confirmed }

        if status.isSignedOrPosted {
            return current == .posted ? .posted : .finalized
        }

        // Журнал записал finalized до фактической подписи (сбой в окне) —
        // безопаснее вернуть ожидание ответа/подписи.
        if current == .finalized {
            return .requestSent
        }
        return nil
    }
}
