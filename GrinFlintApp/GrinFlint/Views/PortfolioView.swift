import SwiftUI

/// Главный экран: баланс, действия, последние транзакции.
struct PortfolioView: View {
    @Environment(WalletViewModel.self) private var viewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    balanceCard
                    if let warning = viewModel.journalWarning {
                        journalWarningCard(warning)
                    }
                    if let pending = viewModel.pendingOperation {
                        PendingOperationCard(operation: pending)
                    }
                    actionButtons
                    recentSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("GrinFlint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .rotationEffect(.degrees(viewModel.isRefreshing ? 360 : 0))
                            .animation(
                                viewModel.isRefreshing
                                    ? .linear(duration: 1).repeatForever(autoreverses: false)
                                    : .default,
                                value: viewModel.isRefreshing
                            )
                    }
                    .disabled(viewModel.isRefreshing)
                    .accessibilityIdentifier("portfolio.refresh")
                }
            }
            // Баннер вставляет отступ в контент, а не накрывает карточку баланса.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error) {
                        viewModel.clearError()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    private func journalWarningCard(_ text: String) -> some View {
        GrinCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Журнал операций", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("portfolio.journalWarning")
    }

    private var balanceCard: some View {
        GrinCard {
            VStack(spacing: 12) {
                Text("Общий баланс")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)

                Text(GrinFormat.grin(viewModel.balance.total))
                    .font(Theme.rounded(34, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                // Явная свежесть данных: ноль при неизвестном балансе —
                // не «достоверный ноль», а отсутствие ответа ноды.
                Text(viewModel.balanceState.freshnessText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        viewModel.balanceState.isUnknown || viewModel.balanceState.isStale
                            ? Theme.warning
                            : Theme.textTertiary
                    )
                    .accessibilityIdentifier("portfolio.balanceState")
                    .accessibilityLabel(viewModel.balanceState.freshnessText)

                HStack(spacing: 16) {
                    balanceChip(title: "Доступно", value: viewModel.balance.spendable)
                    balanceChip(title: "В ожидании", value: viewModel.balance.awaiting)
                    balanceChip(title: "Заблокировано", value: viewModel.balance.locked)
                }

                if viewModel.isDemoMode {
                    Label("Демо-режим: без подключения к сети Grin", systemImage: "flame.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent.opacity(0.9))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func balanceChip(title: String, value: Decimal) -> some View {
        VStack(spacing: 4) {
            Text(GrinFormat.short(value))
                .font(Theme.mono(14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            NavigationLink {
                SendFlowView()
            } label: {
                actionButton(title: "Отправить", icon: "arrow.up", color: Theme.accent)
            }
            .accessibilityIdentifier("portfolio.send")
            NavigationLink {
                ReceiveView()
            } label: {
                actionButton(title: "Получить", icon: "arrow.down", color: Theme.positive)
            }
            .accessibilityIdentifier("portfolio.receive")
        }
    }

    private func actionButton(title: String, icon: String, color: Color) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(height: 62)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Последние операции")
            GrinCard {
                if viewModel.recentTransactions.isEmpty {
                    Text("Пока нет операций")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 6) {
                        ForEach(viewModel.recentTransactions) { tx in
                            NavigationLink {
                                TxDetailView(tx: tx)
                            } label: {
                                TxRow(tx: tx)
                            }
                            .buttonStyle(.plain)
                            if tx.id != viewModel.recentTransactions.last?.id {
                                Divider().overlay(Theme.stroke)
                            }
                        }
                    }
                }
            }
        }
    }
}
