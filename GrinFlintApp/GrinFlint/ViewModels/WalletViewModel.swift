import Foundation
import Observation

@Observable
final class WalletViewModel {
    private let service: WalletService

    private(set) var balance = Balance.zero
    private(set) var transactions: [TransactionRecord] = []
    private(set) var slatepackAddress = ""
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?

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

    /// Загрузить состояние из сервиса (вызывать после open()/refresh()).
    func syncFromService() async {
        balance = await service.balance
        transactions = await service.transactions
        slatepackAddress = await service.slatepackAddress
    }

    var recentTransactions: [TransactionRecord] {
        Array(transactions.prefix(5))
    }

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
            await syncFromService()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareSend(destination: String, amount: Decimal, feeTier: FeeTier) async throws -> SendProposal {
        do {
            let proposal = try await service.prepareSend(destination: destination, amount: amount, feeTier: feeTier)
            await syncFromService()
            // Отправка ещё не завершена: получатель должен вернуть Slatepack.
            TxReminders.schedule(id: proposal.txID.uuidString)
            return proposal
        } catch let error as WalletError {
            errorMessage = error.localizedDescription
            throw error
        }
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
        } catch let error as WalletError {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
