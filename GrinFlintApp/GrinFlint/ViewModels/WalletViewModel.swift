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

    init(service: WalletService = MockWalletService()) {
        self.service = service
        self.isDemoMode = service.isDemo
        self.backendName = service.backendName
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

    func prepareSend(destination: String, amount: Decimal, message: String, feeTier: FeeTier) async throws -> SendProposal {
        do {
            let proposal = try await service.prepareSend(destination: destination, amount: amount, message: message, feeTier: feeTier)
            await syncFromService()
            return proposal
        } catch let error as WalletError {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func receive(slatepack: String, message: String) async throws -> TransactionRecord {
        do {
            let record = try await service.receive(slatepack: slatepack, message: message)
            await syncFromService()
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
        } catch let error as WalletError {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
