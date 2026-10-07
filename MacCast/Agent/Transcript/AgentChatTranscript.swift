import MacCastKit
import RemoteCore
import SwiftUI

struct AgentChatTranscript: View {
    let session: RemoteAgentSession
    @Binding var expandedTools: Set<UUID>
    @Binding var stickToBottom: Bool
    /// A running Codex turn cannot take another question.
    let canSend: Bool
    let queued: [String]
    let unqueue: (Int) -> Void
    let resend: (String) -> Void
    let review: (AgentApproval) -> Void

    private func approval(for item: AgentTranscriptItem) -> AgentApproval? {
        guard case .tool(_, let tool) = item, case .awaitingApproval = tool.state else { return nil }
        return session.transcript.pendingApprovals.first { $0.call.id == tool.call.id }
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.transcript.truncatedAtFront {
                        Text("The start of this conversation is no longer on the Mac.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(session.transcript.items) { item in
                        AgentTranscriptRow(
                            item: item,
                            expandedTools: $expandedTools,
                            canSend: canSend,
                            resend: resend,
                            approval: approval(for: item),
                            review: review
                        )
                        .agentRowArrival()
                    }
                    ForEach(Array(queued.enumerated()), id: \.offset) { offset, text in
                        AgentQueuedRow(text: text, position: offset + 1, total: queued.count) { unqueue(offset) }
                            .agentRowArrival()
                    }
                    if session.transcript.state == .working {
                        AgentThinkingRow()
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    if let failure = session.failure {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(ColorPalette.danger)
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .animation(Motion.settle, value: session.transcript.items.count)
                .animation(Motion.settle, value: queued.count)
                .animation(Motion.settle, value: session.transcript.state == .working)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 40
            } action: { _, atBottom in
                // Manual stick-to-bottom: a default scroll anchor fights a finger that has scrolled up.
                stickToBottom = atBottom
            }
            .onChange(of: session.transcript.items.count) { _, _ in
                guard stickToBottom else { return }
                withAnimation(Motion.settle) { reader.scrollTo("chat-end", anchor: .bottom) }
            }
            .onChange(of: session.id) { _, _ in
                stickToBottom = true
                reader.scrollTo("chat-end", anchor: .bottom)
            }
        }
    }
}
