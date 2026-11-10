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
        .accessibilityIdentifier("continue-in-new-chat")
    }

    /// A stopped chat opens to read. Nothing on the Mac starts, and no tokens are spent re-reading it, until this is tapped.
    func isReadOnly(_ session: RemoteAgentSession) -> Bool {
        AgentPause.isPaused(session.transcript) && !resumedChats.contains(session.id)
    }

    func pausedBar(_ session: RemoteAgentSession) -> some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(Motion.settle) { _ = resumedChats.insert(session.id) }
                composerFocused = true
            } label: {
                Label("Continue this chat", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ColorPalette.onInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(ColorPalette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            Text("Stopped. Continuing makes the agent read the whole conversation again, which uses tokens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier("continue-paused-chat")
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
