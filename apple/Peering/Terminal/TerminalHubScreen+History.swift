import PeeringKit
import RemoteCore
import SwiftUI

extension TerminalHubScreen {
    /// Conversations written to a moment ago on the Mac: a terminal there probably has them open, so they sit with the chats in use and not with the past.
    private var activeOnMac: [AgentResumableSession] {
        guard model.hostSupportsAgentSessionImport else { return [] }
        return (model.resumableSessions ?? []).filter(\.mayBeOpenElsewhere)
    }

    /// Conversations found on the Mac and chats stopped here, newest first. Nothing is remembered on the phone, so the list never shows entries the Mac is about to replace.
    private var historyEntries: [HistoryCard.Entry] {
        let onMac = (model.hostSupportsAgentSessionImport ? model.resumableSessions ?? [] : [])
            .filter { !$0.mayBeOpenElsewhere }
            .map { (date: $0.modifiedAt, entry: macEntry($0)) }
        let paused = model.agentCards.filter(\.isPaused).map { (date: $0.pausedAt, entry: pausedEntry($0)) }
        return (onMac + paused)
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
        let all = historyEntries
        let entries = all.filter { $0.matches(agentHistoryQuery) }
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Controls.sectionLabel(String(localized: "History"), systemImage: "clock.arrow.circlepath")
                HistorySearchField(text: $agentHistoryQuery)
                if entries.isEmpty { HistoryNoMatches() } else { HistoryCard(entries: entries) }
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
            ) : nil,
            peek: {
                if model.hostSupportsAgentSessionPeek { return AnyView(ResumableChatPeek(conversation: session).environment(model)) }
                return AnyView(HistoryInfoPeek(
                    symbol: "sparkles", title: session.title, detail: session.directory, date: session.modifiedAt
                ))
            }
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
            isEnabled: true,
            peek: {
                AnyView(AgentChatPeek(title: card.title, directory: card.directory, session: model.agentSessions.first { $0.id == card.id }).environment(model))
            }
        ) {
            model.selectedAgentSessionID = card.id
            path.append(.chat(card.id))
        }
    }

    /// The folders new terminals were started in, newest first, each one a tap from a new terminal there.
    @ViewBuilder
    var terminalHistorySection: some View {
        let _ = terminalHistoryRevision
        let all = AgentFolderHistory.load().filter { $0.agentID == AgentFolderHistory.terminalAgentID }
        let query = terminalHistoryQuery.trimmingCharacters(in: .whitespaces)
        let folders = query.isEmpty ? all : all.filter {
            $0.path.localizedCaseInsensitiveContains(query)
        }
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Controls.sectionLabel(String(localized: "History"), systemImage: "clock.arrow.circlepath")
                    Spacer(minLength: 8)
                    Button("Clear") {
                        AgentFolderHistory.clear(agentID: AgentFolderHistory.terminalAgentID)
                        terminalHistoryRevision += 1
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                HistorySearchField(text: $terminalHistoryQuery)
                if folders.isEmpty {
                    HistoryNoMatches()
                } else {
                    HistoryCard(entries: folders.prefix(AgentFolderHistory.limit).map(terminalEntry))
                }
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
            isEnabled: true,
            peek: {
                let running = model.terminalCards.first { $0.isRunning && TerminalFolders.folder(for: $0.id) == folder.path }
                if let running { return AnyView(TerminalPeek(terminal: running)) }
                return AnyView(HistoryInfoPeek(
                    symbol: "terminal", title: AgentFolderPath.name(of: folder.path),
                    detail: AgentFolderPath.display(folder.path, home: model.agentPicker.startPath), date: folder.date
                ))
            }
        ) {
            AgentFolderHistory.record(directory: folder.path, agentID: AgentFolderHistory.terminalAgentID, macName: model.hostName)
            model.createTerminal(inDirectory: folder.path)
        }
    }
}
