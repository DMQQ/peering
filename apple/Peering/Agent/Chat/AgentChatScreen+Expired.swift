import PeeringKit
import RemoteCore
import SwiftUI

extension AgentChatScreen {
    /// The conversation stays readable above; the way forward is a new chat that starts from a recap of it.
    func expiredBar(_ session: RemoteAgentSession) -> some View {
        Button { model.continueInNewChat(from: session) } label: {
            Label("Continue in a new chat", systemImage: "arrow.uturn.forward")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ColorPalette.onInk)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(ColorPalette.ink, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityIdentifier("continue-in-new-chat")
    }

    /// A chat opened to stand in for one that could not be reopened starts with its recap in the composer, to read and send.
    func seedDraftIfNew() {
        guard let session, session.transcript.isEmpty, (drafts[currentID] ?? "").isEmpty,
              let seed = ChatSeed.take(agentID: session.agentID)
        else { return }
        drafts[currentID] = seed
    }

    func emptyChat(_ session: RemoteAgentSession) -> some View {
        AgentEmptyChat(
            agent: TerminalAgent.all.first { $0.id == session.agentID },
            session: session,
            compact: composerFocused
        ) { text in
            stickToBottom = true
            model.sendAgentPrompt(text, to: session.id)
        }
    }

    var ended: some View {
        VStack(spacing: 6) {
            Text("This chat has ended.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ColorPalette.ink)
            Text("Start a new one from Mac terminals.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
