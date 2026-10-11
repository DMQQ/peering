import MacCastKit
import RemoteCore
import SwiftUI

extension TerminalHubScreen {
    @ViewBuilder
    var chatsSection: some View {
        let active = model.agentCards.filter { !$0.isPaused }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Controls.sectionLabel("Chats", systemImage: "bubble.left.and.text.bubble.right")
                VStack(spacing: 10) {
                    ForEach(Array(active.enumerated()), id: \.element.id) { index, session in
                        chatRow(session, index: index)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    private func chatBadge(_ card: AgentCardDigest) -> SessionBadge {
        if card.isPaused { return .paused }
        switch card.state {
        case .idle: return .finished
        case .working: return .working
        case .awaitingApproval: return .needsYou
        case .exited: return .ended
        case .failed: return .failed
        }
    }

    private func chatRow(_ session: AgentCardDigest, index: Int) -> some View {
        let agent = TerminalAgent.all.first { $0.id == session.agentID }
        let folder = (session.directory as NSString).lastPathComponent
        return Button {
            model.selectedAgentSessionID = session.id
            path.append(.chat(session.id))
        } label: {
            SessionCard(
                symbol: agent?.symbol ?? "sparkles",
                title: session.title,
                badge: chatBadge(session),
                index: index,
                folder: folder.isEmpty ? nil : folder,
                preview: session.preview,
                activity: session.activity,
                plan: session.plan,
                startedAt: session.createdAt,
                isRunning: session.isLive
            ) {
                // The title usually starts with the agent's name already: saying it twice wrapped the row.
                if !session.title.localizedCaseInsensitiveContains(agent?.name ?? session.agentID) {
                    Text(verbatim: agent?.name ?? session.agentID)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Continuing a chat whose CLI has gone: a new conversation with the same agent in the
            // same folder, which is as close to picking it up as either CLI offers.
            Button("New chat here", systemImage: "plus.bubble") {
                model.startAgentChat(agentID: session.agentID, directory: session.directory)
            }
            .menuInk()
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(session) }
                .menuInk()
            if model.hostSupportsAgentPause, session.state == .idle, !session.isPaused {
                Button("Stop and move to history", systemImage: "archivebox", role: .destructive) { model.pauseAgentSession(session.id) }
                    .menuDanger()
            }
            Button("Close", systemImage: "xmark", role: .destructive) { pendingEnd = .chat(session.id) }
                .menuDanger()
        } preview: {
            AgentChatPeek(card: session, session: model.agentSessions.first { $0.id == session.id })
                .environment(model)
        }
        .accessibilityIdentifier("chat-row")
    }
}
