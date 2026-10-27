import SwiftUI

/// Полная история транзакций с группировкой по дням.
struct TransactionsView: View {
    @Environment(WalletViewModel.self) private var viewModel

    private struct DayGroup: Identifiable {
        var id: String { date }
        let date: String
        let txs: [TransactionRecord]
    }

    private var grouped: [DayGroup] {
        let groupedDict = Dictionary(grouping: viewModel.transactions) {
            TxDate.section($0.createdAt)
        }
        return groupedDict
            .map { DayGroup(date: $0.key, txs: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { ($0.txs.first?.createdAt ?? .distantPast) > ($1.txs.first?.createdAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if viewModel.transactions.isEmpty {
                    ContentUnavailableView(
                        "Нет транзакций",
                        systemImage: "tray",
                        description: Text("История операций появится здесь")
                    )
                    .foregroundStyle(Theme.textSecondary)
                } else {
                    VStack(spacing: 18) {
                        ForEach(grouped) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: group.date)
                                GrinCard {
                                    VStack(spacing: 6) {
                                        ForEach(group.txs) { tx in
                                            NavigationLink {
                                                TxDetailView(tx: tx)
                                            } label: {
                                                TxRow(tx: tx)
                                            }
                                            .buttonStyle(.plain)
                                            if tx.id != group.txs.last?.id {
                                                Divider().overlay(Theme.stroke)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Транзакции")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Детали одной транзакции.
struct TxDetailView: View {
    let tx: TransactionRecord

    @Environment(WalletViewModel.self) private var viewModel
    @State private var showExport = false
    @State private var exportedSlatepack = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                detailsCard
                if tx.slatepack != nil {
                    exportSection
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Детали")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: tx.type == .sent ? "arrow.up" : (tx.type == .coinbase ? "hammer.fill" : "arrow.down"))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(tx.type == .sent ? Theme.textPrimary : Theme.positive)
                .padding(18)
                .background(Theme.surfaceLight)
                .clipShape(Circle())

            Text(GrinFormat.grin(tx.amount.magnitude))
                .font(Theme.rounded(32, weight: .bold))
                .foregroundStyle(tx.type == .sent ? Theme.textPrimary : Theme.positive)

            Text(tx.status.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(statusColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.top, 8)
    }

    private var detailsCard: some View {
        GrinCard {
            VStack(spacing: 14) {
                detailRow(title: "Тип", value: typeTitle)
                detailRow(title: "Комиссия", value: tx.fee > 0 ? GrinFormat.grin(tx.fee) : "—")
                detailRow(title: "Дата", value: "\(TxDate.section(tx.createdAt)), \(TxDate.time(tx.createdAt))")
                if !tx.message.isEmpty {
                    detailRow(title: "Сообщение", value: tx.message)
                }
                if let counterpart = tx.counterpart {
                    detailRow(title: "Контрагент", value: counterpart)
                }
                detailRow(title: "ID", value: tx.id.uuidString.prefix(13).description + "…")
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Slatepack не отправлен")
            GrinCard {
                VStack(spacing: 12) {
                    Text("Эта транзакция ещё не передана получателю. Экспортируйте Slatepack и отправьте его.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    Button("Показать Slatepack") {
                        Task {
                            exportedSlatepack = await viewModel.exportSlatepack(txID: tx.id) ?? ""
                            showExport = true
                        }
                    }
                    .buttonStyle(GrinButtonStyle(isSecondary: true))
                }
            }
        }
        .sheet(isPresented: $showExport) {
            NavigationStack {
                ScrollView {
                    CopyableField(title: "Slatepack для получателя", value: exportedSlatepack, isMultiline: true)
                        .padding(16)
                }
                .background(Theme.background.ignoresSafeArea())
                .navigationTitle("Экспорт Slatepack")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 100, alignment: .leading)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var typeTitle: String {
        switch tx.type {
        case .sent: return "Отправлено"
        case .received: return "Получено"
        case .coinbase: return "Награда за блок"
        }
    }

    private var statusColor: Color {
        switch tx.status {
        case .confirmed: return Theme.positive
        case .unconfirmed: return Theme.warning
        case .failed: return Theme.negative
        }
    }
}
