import Foundation
import Observation

@Observable
final class WalletViewModel {
    private let service: WalletService

    /// Баланс вместе со свежестью: нули при `unknown` не считаются
    /// достоверными, при `stale` показаны последние известные значения.
    private(set) var balanceState = BalanceState.initial
    /// Текущие значения для экранов (свежесть — в `balanceState`).
    var balance: Balance { balanceState.balance }
    private(set) var transactions: [TransactionRecord] = []
    private(set) var slatepackAddress = ""
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    /// Незавершённый перевод (этап операции сохранён на диск).
    private(set) var pendingOperation: PendingOperation?
    /// Проблема журнала операций (повреждён/не записывается).
    private(set) var journalWarning: String?

    /// Демо-режим: сервис работает без сети Grin (MockWalletService).
    let isDemoMode: Bool
    /// Имя блокчейн-бэкенда для экрана настроек.
    let backendName: String
    /// Причина недоступности реального сервиса (nil — всё в порядке).
    let unavailableReason: String?

    init(service: WalletService = MockWalletService()) {
        self.service = service
        self.isDemoMode = service.isDemo
        self.backendName = service.backendName
        self.unavailableReason = service.unavailableReason
    }

    /// Загрузить состояние из сервиса (вызывать после open()/операций).
    /// Свежесть от ноды не меняется: значения могут быть из локальной БД.
    func syncFromService() async {
        balanceState.updateLocally(await service.balance)
        transactions = await service.transactions
        slatepackAddress = await service.slatepackAddress
        pendingOperation = await service.pendingOperation
        journalWarning = await service.journalWarning
    }

    /// Убрать запись о приёме после того, как ответ передан отправителю.
    func dismissPending() async {
        guard let operation = pendingOperation else { return }
        await service.dismissPending(id: operation.id)
        await syncFromService()
    }

    var recentTransactions: [TransactionRecord] {
        Array(transactions.prefix(5))
    }

    var hasPendingOperation: Bool { pendingOperation != nil }

    func clearError() {
        errorMessage = nil
    }

    /// Показать ошибку, пришедшую не из операций сервиса (например, при старте).
    func reportError(_ message: String) {
        errorMessage = message
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await service.refresh()
            // Успешный ответ ноды: баланс достоверен.
            balanceState.updateFromNode(await service.balance)
            transactions = await service.transactions
            pendingOperation = await service.pendingOperation
            slatepackAddress = await service.slatepackAddress
        } catch {
            // Прежние значения не обнуляем: помечаем их как устаревшие.
            balanceState.fail(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Оценка комиссии до подписания (не блокирует средства).
    func estimateFee(destination: String, amountText: String) async throws -> FeeQuote {
        try await service.estimateFee(destination: destination, amountText: amountText)
    }

    /// Максимум к отправке с учётом настоящей комиссии.
    func maxSendable(destination: String) async throws -> MaxSendable {
        try await service.maxSendable(destination: destination)
    }

    func prepareSend(destination: String, amountText: String) async throws -> SendProposal {
        do {
            let proposal = try await service.prepareSend(destination: destination, amountText: amountText)
            await syncFromService()
            // Отправка ещё не завершена: получатель должен вернуть Slatepack.
            TxReminders.schedule(id: proposal.txID.uuidString)
            return proposal
        } catch let error as WalletError {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Отметить, что запрос передан получателю (стадия requestSent).
    func markRequestSent(operationID: UUID) async {
        await service.markRequestSent(id: operationID)
        await syncFromService()
    }

    /// Отменить перевод до финализации.
    func cancelPending(operationID: UUID) async throws {
        try await service.cancel(operationID: operationID)
        await syncFromService()
        TxReminders.cancelAll()
    }

    /// Повторить публикацию подписанной транзакции без новой подписи.
    func repostPending(operationID: UUID) async throws {
        try await service.repost(operationID: operationID)
        await syncFromService()
    }

    func receive(slatepack: String) async throws -> TransactionRecord {
        do {
            let record = try await service.receive(slatepack: slatepack)
            await syncFromService()
            if record.responseSlatepack != nil {
                // Приём тоже интерактивный: ответ нужно вернуть отправителю.
                TxReminders.schedule(id: record.id.uuidString)
            }
            return record
        } catch let error as WalletError {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func exportSlatepack(txID: UUID) async -> String? {
        await service.exportSlatepack(txID: txID)
    }

    /// Завершить отправку ответным Slatepack получателя.
    func finalize(slatepackResponse: String) async throws {
        let trimmed = slatepackResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WalletError.invalidSlatepack }
        do {
            try await service.finalize(slatepackResponse: trimmed)
            await syncFromService()
            // Незавершённых интерактивных транзакций больше нет.
            TxReminders.cancelAll()
        } catch {
            // Журнал мог измениться даже при ошибке: FFI сохраняет стадию
            // finalized и подписанный Slate, чтобы UI предложил повтор
            // публикации без новой подписи.
            await syncFromService()
            if let walletError = error as? WalletError {
                errorMessage = walletError.localizedDescription
            }
            throw error
        }
    }
}
