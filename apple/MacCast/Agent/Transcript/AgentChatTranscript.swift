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
    let openSubagent: (String) -> Void

    /// What was already in the transcript when it appeared; nil until then, so a conversation being opened is never typed out.
    @State private var present: Set<UUID>?
    /// Scrolling a transcript shorter than its viewport pushes the offset negative and snaps back, which reads as flicker.
    @State private var overflows = false

    private func scrollToEnd(_ reader: ScrollViewProxy, animated: Bool = false) {
        guard overflows else { return }
        if animated {
            withAnimation(Motion.settle) { reader.scrollTo("chat-end", anchor: .bottom) }
        } else {
            reader.scrollTo("chat-end", anchor: .bottom)
        }
    }

    /// Only the newest reply, and only if it arrived while this screen was open.
    private func streams(_ item: AgentTranscriptItem) -> Bool {
        guard let present, case .reply(let id, _) = item, !present.contains(id) else { return false }
        let lastReply = session.transcript.items.last { if case .reply = $0 { return true } else { return false } }
        return lastReply?.id == id
    }

    private func approval(for item: AgentTranscriptItem) -> AgentApproval? {
        guard case .tool(_, let tool) = item, case .awaitingApproval = tool.state else { return nil }
        return session.transcript.pendingApprovals.first { $0.call.id == tool.call.id }
    }

    private func subagent(for item: AgentTranscriptItem) -> AgentTranscript? {
        guard case .tool(_, let tool) = item else { return nil }
        return session.transcript.children[tool.call.id]
    }

    private func subagentOpener(for item: AgentTranscriptItem) -> (() -> Void)? {
        guard case .tool(_, let tool) = item, subagent(for: item) != nil else { return nil }
        return { openSubagent(tool.call.id) }
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
                            review: review,
                            openSubagent: subagentOpener(for: item),
                            subagentSteps: subagent(for: item)?.items.count,
                            streams: streams(item),
                            onReveal: { if stickToBottom { scrollToEnd(reader) } }
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
                        Text(HostWireText.localized(failure))
                            .font(.footnote)
                            .foregroundStyle(ColorPalette.danger)
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .scrollsToTopDisabled()
                .animation(Motion.settle, value: session.transcript.items.count)
                .animation(Motion.settle, value: queued.count)
                .animation(Motion.settle, value: session.transcript.state == .working)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            // A chat opens at its latest message. Only the first layout: later growth is the manual stick-to-bottom below.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height > geometry.containerSize.height
            } action: { _, now in
                overflows = now
                if now && stickToBottom { reader.scrollTo("chat-end", anchor: .bottom) }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 40
            } action: { _, atBottom in
                // Manual stick-to-bottom: a default scroll anchor fights a finger that has scrolled up.
                stickToBottom = atBottom
            }
            .onChange(of: session.transcript.items.count) { old, _ in
                // A conversation read back from the Mac arrives after the screen does: that first fill lands on its end, not its top, and without animating past the whole history.
                if old == 0 {
                    stickToBottom = true
                    scrollToEnd(reader)
                } else if stickToBottom {
                    scrollToEnd(reader, animated: true)
                }
            }
            .onAppear {
                present = Set(session.transcript.items.map(\.id))
                scrollToEnd(reader)
            }
            .onChange(of: session.id) { _, _ in
                present = Set(session.transcript.items.map(\.id))
                stickToBottom = true
                scrollToEnd(reader)
            }
        }
    }
}
