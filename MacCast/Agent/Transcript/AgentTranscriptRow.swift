import MacCastKit
import RemoteCore
import SwiftUI

struct AgentTranscriptRow: View {
    let item: AgentTranscriptItem
    @Binding var expandedTools: Set<UUID>
    let canSend: Bool
    let resend: (String) -> Void
    /// Set while this tool call is the question the agent is waiting on.
    var approval: AgentApproval?
    var review: (AgentApproval) -> Void = { _ in }

    var body: some View {
        switch item {
        case .user(let id, let text):
            let (files, rest) = AgentMentions.split(text)
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(files, id: \.self) { path in
                        AgentFileChip(name: (path as NSString).lastPathComponent, symbol: AgentFileGlyph.symbol(for: path))
                    }
                    if !rest.isEmpty || files.isEmpty {
                        AgentPlainText(text: files.isEmpty ? text : rest)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [.white.opacity(0.09), .white.opacity(0.045)],
                                        startPoint: .top, endPoint: .bottom
                                    ))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(.white.opacity(0.07))
                            }
                    }
                }
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        .menuInk()
                    if canSend {
                        Button("Ask again", systemImage: "arrow.clockwise") { resend(text) }
                            .menuInk()
                    }
                }
            }
            .id(id)

        case .reply(let id, let text):
            AgentMarkdownText(text: text)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        .menuInk()
                }
                .id(id)

        case .tool(let id, let tool):
            AgentToolCard(tool: tool, isExpanded: expandedTools.contains(id)) {
                if let approval {
                    review(approval)
                    return
                }
                withAnimation(Motion.settle) {
                    if expandedTools.contains(id) { expandedTools.remove(id) } else { expandedTools.insert(id) }
                }
            }
            .contextMenu {
                if let output = tool.output, !output.isEmpty {
                    Button("Copy output", systemImage: "doc.on.doc") { UIPasteboard.general.string = output }
                        .menuInk()
                }
                if let detail = tool.call.detail, !detail.isEmpty {
                    Button("Copy \(tool.call.title)", systemImage: "terminal") { UIPasteboard.general.string = detail }
                        .menuInk()
                }
                Button(
                    expandedTools.contains(id) ? "Hide details" : "Show details",
                    systemImage: expandedTools.contains(id) ? "chevron.up" : "chevron.down"
                ) {
                    withAnimation(Motion.settle) {
                        if expandedTools.contains(id) { expandedTools.remove(id) } else { expandedTools.insert(id) }
                    }
                }
                .menuInk()
            }
            .id(id)

        case .notice(_, let text):
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text(text)
                    .font(.footnote)
            }
            .foregroundStyle(.white.opacity(0.5))

        case .failure(_, let text):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                Text(text)
                    .font(.footnote)
            }
            .foregroundStyle(ColorPalette.danger)

        case .summary(_, let summary):
            AgentTurnSummaryPill(summary: summary)
        }
    }
}
