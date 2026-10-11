import MacCastKit
import RemoteCore
import SwiftUI

extension TerminalHubScreen {
    /// Conversations written to a moment ago on the Mac: a terminal there probably has them open, so they sit with the chats in use and not with the past.
    private var activeOnMac: [AgentResumableSession] {
        guard model.hostSupportsAgentSessionImport else { return [] }
        return (model.resumableSessions ?? []).filter(\.mayBeOpenElsewhere)
    }

    /// Agents launched from here and conversations found on the Mac, newest first: both are a way back into something already done.
    private var historyEntries: [HistoryCard.Entry] {
        let launched = history.map { (date: $0.date, entry: historyEntry($0)) }
        let onMac = (model.hostSupportsAgentSessionImport ? model.resumableSessions ?? [] : [])
            .filter { !$0.mayBeOpenElsewhere }
            .map { (date: $0.modifiedAt, entry: macEntry($0)) }
        let paused = model.agentCards.filter(\.isPaused).map { (date: $0.pausedAt, entry: pausedEntry($0)) }
        return (launched + onMac + paused)
            .sorted { $0.date > $1.date }
            .prefix(SessionModel.terminalHistoryLimit)
            .map(\.entry)
    }

    @ViewBuilder
    var activeOnMacSection: some View {
        let sessions = activeOnMac
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Controls.sectionLabel(String(localized: "Active on your Mac"), systemImage: "laptopcomputer")
                HistoryCard(entries: sessions.map(macEntry))
            }
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    var historySection: some View {
        let entries = historyEntries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Controls.sectionLabel("History", systemImage: "clock.arrow.circlepath")
                    Spacer(minLength: 8)
                    if !history.isEmpty {
                        Button("Clear") {
                            AgentHistory.clear()
                            history = []
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
                HistoryCard(entries: entries)
            }
            .padding(.top, 20)
        } else if activeOnMac.isEmpty, model.hostSupportsAgentSessionImport, model.resumableSessions?.isEmpty == true {
            Text("No Claude conversations found on your Mac. Chats from your Desktop, Documents or Downloads only show up once Peering is allowed there: on the Mac, open System Settings, Privacy & Security, Files and Folders.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 20)
        }
    }

    private func macEntry(_ session: AgentResumableSession) -> HistoryCard.Entry {
        HistoryCard.Entry(
            id: session.id,
            symbol: "sparkles",
            title: session.title,
            detail: (session.directory as NSString).lastPathComponent,
            date: session.modifiedAt,
            isLive: false,
            isEnabled: true,
            confirmation: session.mayBeOpenElsewhere ? HistoryCard.Confirmation(
                title: "This conversation may be open on your Mac",
                message: "It was written to a moment ago. If a terminal still has it open, both would add to the same conversation.",
                proceed: "Continue here anyway"
            ) : nil
        ) {
            model.resumeAgentSession(session)
        }
    }

    private func pausedEntry(_ card: AgentCardDigest) -> HistoryCard.Entry {
        let folder = (card.directory as NSString).lastPathComponent
        return HistoryCard.Entry(
            id: card.id.uuidString,
            symbol: TerminalAgent.all.first { $0.id == card.agentID }?.symbol ?? "sparkles",
            title: card.title,
            detail: folder,
            date: card.pausedAt,
            isLive: false,
            isEnabled: true
        ) {
            model.selectedAgentSessionID = card.id
            path.append(.chat(card.id))
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
            isEnabled: true
        ) {
            AgentFolderHistory.record(directory: folder.path, agentID: AgentFolderHistory.terminalAgentID, macName: model.hostName)
            model.createTerminal(inDirectory: folder.path)
        }
    }
}
