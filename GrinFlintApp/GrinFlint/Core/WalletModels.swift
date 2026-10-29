import Foundation

/// Тип транзакции.
enum TxType: String, Codable {
    case sent
    case received
    case coinbase
}

/// Статус подтверждения (Mimblewimble: подтверждение = появление в блоке).
enum TxStatus: String, Codable {
    case unconfirmed
    case confirmed
    /// Транзакция откатилась (reorg) или отменена — средства возвращены.
    case reverted
    case failed

    var title: String {
        switch self {
        case .unconfirmed: return "Не подтверждено"
        case .confirmed: return "Подтверждено"
        case .reverted: return "Возвращено"
        case .failed: return "Ошибка"
        }
    }
}

/// Остатки кошелька.
struct Balance: Equatable {
    /// Доступно к трате (зрелые выходы).
    var spendable: Decimal
    /// Неподтверждённые входящие.
    var awaiting: Decimal
    /// Заблокировано исходящими транзакциями.
    var locked: Decimal

    var total: Decimal { spendable + awaiting + locked }

    static let zero = Balance(spendable: 0, awaiting: 0, locked: 0)
}

/// Запись транзакции в истории.
struct TransactionRecord: Identifiable, Equatable {
    let id: UUID
    var type: TxType
    var status: TxStatus
    var amount: Decimal      // для sent — отрицательная сумма с учётом комиссии
    var fee: Decimal
    var message: String
    var slatepack: String?   // Slatepack, если транзакция ещё не передана контрагенту
    var counterpart: String? // адрес/примечание контрагента
    let createdAt: Date
    /// Ответный Slatepack входящей транзакции (FFI-режим): его нужно вернуть
    /// отправителю, чтобы тот завершил перевод. У исходящих и демо — nil.
    var responseSlatepack: String? = nil

    static func == (lhs: TransactionRecord, rhs: TransactionRecord) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.amount == rhs.amount
    }
}

/// Предложение на отправку, возвращаемое сервисом перед подписанием.
struct SendProposal {
    var amount: Decimal
    var fee: Decimal
    var slatepack: String
    var txID: UUID
}

/// Реальная оценка комиссии от grin-wallet (`estimate_only`, без блокировки
/// средств). Комиссия считается по выбранным входам до подписания.
struct FeeQuote: Equatable {
    var amount: Decimal
    var fee: Decimal
    var total: Decimal
}

/// Максимум к отправке с учётом настоящей комиссии.
struct MaxSendable: Equatable {
    var amount: Decimal
    var fee: Decimal
}
