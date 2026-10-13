import PeeringKit
import SwiftUI

/// What a long press on a chat card shows without opening it: the conversation itself, scrolled to its end and not answerable.
struct AgentChatPeek: View {
    let card: AgentCardDigest
    let session: RemoteAgentSession?

    @State private var expandedTools: Set<UUID> = []
    @State private var stickToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                Text(verbatim: (card.directory as NSString).lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            if let session, !session.transcript.isEmpty {
                AgentChatTranscript(
                    session: session,
                    expandedTools: $expandedTools,
                    stickToBottom: $stickToBottom,
                    canSend: false,
                    queued: [],
                    unqueue: { _ in },
                    resend: { _ in },
                    review: { _ in },
                    openSubagent: { _ in }
                )
                .allowsHitTesting(false)
            } else {
                Text(session?.isLoaded == true ? "Nothing said yet" : "Loading the conversation")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 360, height: 480)
        .background(ColorPalette.backdrop)
        .preferredColorScheme(.dark)
    }
}
