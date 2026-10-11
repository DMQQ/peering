import MacCastKit
import RemoteCore
import SwiftUI

struct AgentToolCard: View {
    let tool: AgentToolItem
    let isExpanded: Bool
    var subagentSteps: Int?
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: tool.state == .ok)
                        .symbolEffect(.variableColor.iterative, isActive: tool.state == .running)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.call.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        if let detail = tool.call.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(isExpanded ? nil : 2)
                        }
                        if let steps = subagentSteps {
                            Text("\(steps) steps, tap to open")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    Spacer(minLength: 6)
                    // As tall as the icon tile, so an expanded header keeps both at its top and not on its middle.
                    statusGlyph.frame(height: 28)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let diff = tool.call.diff, !diff.isEmpty {
                    AgentDiffBlock(diff: diff)
                }
                if let output = tool.output, !output.isEmpty {
                    AgentMonospaceBlock(text: tool.truncated ? output + "\n… (truncated)" : output)
                }
                if tool.call.diff == nil, tool.output == nil, tool.state == .running {
                    Text("Running…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(11)
        // A block leaving on collapse is drawn on for a few frames after the card's frame has shrunk past it, which put it over the row that slid up into its place.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.clear)
        }
        .runningEdge(tool.state == .running, radius: 16)
        .animation(Motion.settle, value: tool.state)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
    }

    private var symbol: String {
        switch tool.state {
        case .awaitingApproval: return "hand.raised"
        case .denied: return "nosign"
        case .failed: return "xmark"
        case .ok: return "checkmark"
        case .running: return "ellipsis"
        }
    }

    private var tint: Color {
        switch tool.state {
        case .awaitingApproval, .denied: return ColorPalette.caution
        case .failed: return ColorPalette.danger
        case .ok, .running: return .white.opacity(0.85)
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch tool.state {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(.white.opacity(0.6))
        case .awaitingApproval:
            Text("Review")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ColorPalette.onInk)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(ColorPalette.ink))
        case .denied:
            Text("Denied")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ColorPalette.caution)
        case .failed:
            Text("Failed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ColorPalette.danger)
        case .ok:
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}
