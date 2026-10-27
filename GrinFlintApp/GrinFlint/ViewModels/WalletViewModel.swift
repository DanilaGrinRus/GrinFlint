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

    /// Демо-режим: без подключения к ноде и grin-wallet.
    let isDemoMode = true

    init(service: WalletService = MockWalletService()) {
        self.service = service
        self.balance = service.balance
        self.transactions = service.transactions
        self.slatepackAddress = service.slatepackAddress
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
            syncFromService()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareSend(destination: String, amount: Decimal, message: String, feeTier: FeeTier) async throws -> SendProposal {
        do {
            let proposal = try await service.prepareSend(destination: destination, amount: amount, message: message, feeTier: feeTier)
            syncFromService()
            return proposal
        } catch let error as WalletError {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func receive(slatepack: String, message: String) async throws -> TransactionRecord {
        do {
            let record = try await service.receive(slatepack: slatepack, message: message)
            syncFromService()
            return record
        } catch let error as WalletError {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func exportSlatepack(txID: UUID) async -> String? {
        await service.exportSlatepack(txID: txID)
    }

    private func syncFromService() {
        balance = service.balance
        transactions = service.transactions
    }
}
