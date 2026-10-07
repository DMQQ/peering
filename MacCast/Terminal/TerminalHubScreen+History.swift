import MacCastKit
import RemoteCore
import SwiftUI

extension TerminalHubScreen {
    @ViewBuilder
    var historySection: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Controls.sectionLabel("History", systemImage: "clock.arrow.circlepath")
                    Spacer(minLength: 8)
                    Button("Clear") {
                        AgentHistory.clear()
                        history = []
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                HistoryCard(entries: history.prefix(20).map(historyEntry))
            }
            .padding(.top, 20)
        }
    }

    private func historyEntry(_ entry: AgentLaunch) -> HistoryCard.Entry {
        let agent = TerminalAgent.all.first { $0.id == entry.agentID }
        let live = entry.terminalID.flatMap { id in
            model.terminalCards.first { $0.id == id && $0.isRunning }?.id
        }
        return HistoryCard.Entry(
            id: entry.id,
            symbol: agent?.symbol ?? "sparkles",
            title: agent?.name ?? entry.agentID,
            detail: entry.macName,
            date: entry.date,
            isLive: live != nil,
            isEnabled: agent != nil || live != nil
        ) {
            if let live {
                model.selectTerminal(live)
                path.append(.terminal(live))
            } else if let agent {
                start(agent, restarting: entry)
            }
        }
    }
}
