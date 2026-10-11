import MacCastKit
import RemoteCore
import SwiftUI

extension TerminalHubScreen {
    @ViewBuilder
    var chatsSection: some View {
        if !model.agentCards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Controls.sectionLabel("Chats", systemImage: "bubble.left.and.text.bubble.right")
                VStack(spacing: 10) {
                    ForEach(Array(model.agentCards.enumerated()), id: \.element.id) { index, session in
                        chatRow(session, index: index)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    /// Offered only by a Mac that can list its terminal conversations. One line, since it is an occasional door and not a card of content.
    @ViewBuilder
    var resumeEntry: some View {
        if model.hostSupportsAgentSessionImport {
            Button {
                path.append(.resumable)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22)
                    Text("Continue from your Mac")
                        .font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14)))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .accessibilityIdentifier("resume-entry")
        }
    }

    private func chatBadge(_ state: AgentSessionState) -> SessionBadge {
        switch state {
        case .idle: return .ready
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
                badge: chatBadge(session.state),
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
            Button("Close", systemImage: "xmark", role: .destructive) { pendingEnd = .chat(session.id) }
                .menuDanger()
        } preview: {
            AgentChatPeek(card: session, session: model.agentSessions.first { $0.id == session.id })
                .environment(model)
        }
        .accessibilityIdentifier("chat-row")
    }
}
