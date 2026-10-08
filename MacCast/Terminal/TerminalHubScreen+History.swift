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
                HistoryCard(entries: history.prefix(SessionModel.terminalHistoryLimit).map(historyEntry))
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
            id: entry.id.uuidString,
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

    /// The folders new terminals were started in, newest first, each one a tap from a new terminal there.
    @ViewBuilder
    var terminalHistorySection: some View {
        let _ = terminalHistoryRevision
        let folders = AgentFolderHistory.load().filter { $0.agentID == AgentFolderHistory.terminalAgentID }
        if !folders.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Controls.sectionLabel("History", systemImage: "clock.arrow.circlepath")
                    Spacer(minLength: 8)
                    Button("Clear") {
                        AgentFolderHistory.clear(agentID: AgentFolderHistory.terminalAgentID)
                        terminalHistoryRevision += 1
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                HistoryCard(entries: folders.prefix(AgentFolderHistory.limit).map(terminalEntry))
            }
            .padding(.top, 20)
        }
    }

    private func terminalEntry(_ folder: AgentFolderHistory.Entry) -> HistoryCard.Entry {
        HistoryCard.Entry(
            id: folder.path,
            symbol: "terminal",
            title: AgentFolderPath.name(of: folder.path),
            detail: AgentFolderPath.display(folder.path, home: model.agentPicker.startPath),
            date: folder.date,
            isLive: false,
            isEnabled: model.canOpenAnotherShell
        ) {
            AgentFolderHistory.record(directory: folder.path, agentID: AgentFolderHistory.terminalAgentID, macName: model.hostName)
            model.createTerminal(inDirectory: folder.path)
        }
    }
}
