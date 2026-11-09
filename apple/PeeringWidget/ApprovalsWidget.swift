import SwiftUI
import WidgetKit

/// Only the chats waiting on an answer, on the Home and Lock Screens, each a link into the question.
struct ApprovalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PeeringApprovals", provider: ApprovalsProvider()) { entry in
            ApprovalsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Waiting on you")
        .description("The agent chats that are asking for an answer.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

private struct ApprovalsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ApprovalsEntry { ApprovalsEntry(date: Date(), waiting: []) }

    func getSnapshot(in context: Context, completion: @escaping (ApprovalsEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ApprovalsEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> ApprovalsEntry {
        ApprovalsEntry(date: Date(), waiting: AgentChatSnapshot.ordered(SharedStore.agentChats).filter { $0.state == .needsYou })
    }
}

private struct ApprovalsEntry: TimelineEntry {
    let date: Date
    let waiting: [AgentChatSnapshot]
}

private struct ApprovalsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ApprovalsEntry

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    private var inline: some View {
        Text(entry.waiting.isEmpty ? String(localized: "Nothing waiting") : String(localized: "\(entry.waiting.count) waiting on you"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.waiting.isEmpty ? String(localized: "Nothing waiting") : String(localized: "\(entry.waiting.count) waiting on you"))
                .font(.headline)
            if let top = entry.waiting.first {
                Text(top.title).font(.caption).lineLimit(1).privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(entry.waiting.first?.url)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bell.badge").foregroundStyle(entry.waiting.isEmpty ? .secondary : WidgetTint.state)
            Spacer(minLength: 0)
            Text("\(entry.waiting.count)").font(.system(size: 34, weight: .semibold, design: .rounded))
            Text(entry.waiting.first?.title ?? String(localized: "Nothing waiting"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .privacySensitive()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(entry.waiting.first?.url)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting on you").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if entry.waiting.isEmpty {
                Spacer(minLength: 0)
                Text("Questions from your agents show up here.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.waiting.prefix(3)) { chat in
                    Link(destination: chat.url) {
                        HStack(spacing: 8) {
                            Circle().fill(WidgetTint.state).frame(width: 7, height: 7)
                            Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(chat.folder).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
