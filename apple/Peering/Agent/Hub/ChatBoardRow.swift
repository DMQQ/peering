import PeeringKit
import SwiftUI

/// One chat on the board: what it is, where it runs, and the last thing said.
struct ChatBoardRow: View {
    let entry: ChatBoardEntry
    let showsMacName: Bool

    private var agent: TerminalAgent? { TerminalAgent.all.first { $0.id == entry.agentID } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: agent?.symbol ?? "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 34, height: 34)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(entry.changedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                    if entry.isUnread, entry.group == .done {
                        Circle()
                            .fill(ColorPalette.ink)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel(String(localized: "Unread"))
                    }
                }
                Text(verbatim: origin)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                if let snippet = entry.snippet {
                    Text(verbatim: snippet)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var origin: String {
        let name = agent?.name ?? entry.agentID
        return showsMacName ? "\(name) · \(entry.macName)" : name
    }
}
