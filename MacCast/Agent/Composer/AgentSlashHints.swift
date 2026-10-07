import MacCastKit
import RemoteCore
import SwiftUI

extension SlashSuggestion {
    var symbol: String {
        switch kind {
        case .app: return "iphone"
        case .builtin: return "command"
        case .command: return "slash.circle"
        case .skill: return "wand.and.stars"
        }
    }

    var tag: LocalizedStringKey {
        switch kind {
        case .app: return "In Peering"
        case .builtin: return "Built in"
        case .command: return "Command"
        case .skill: return "Skill"
        }
    }

    var detailText: String {
        switch detail {
        case .usage: return String(localized: "Open usage and limits")
        case .model: return String(localized: "Choose the model")
        case .rename: return String(localized: "Rename this chat")
        case .compact: return String(localized: "Summarise the conversation to free up context")
        case .clear: return String(localized: "Start over with an empty context")
        case .thisProject: return String(localized: "This project")
        case .yours: return String(localized: "Yours")
        }
    }
}

/// The suggestions with what each one does.
struct AgentSlashList: View {
    let items: [SlashSuggestion]
    let pick: (SlashSuggestion) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text("Nothing matches")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 46) }
                    Button { pick(item) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: "/" + item.name)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ColorPalette.ink)
                                    .lineLimit(1)
                                Text(verbatim: item.detailText)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(item.tag)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 264)
        .background(ColorPalette.backdrop, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}
