import SwiftUI
import WidgetKit

/// The agent chats on the Home and Lock Screens: which is waiting on you, which is busy, and how far through its plan.
///
/// A tap opens the chat. The app writes the list (see `AgentWidgetPublisher`), so the widget asks nothing.
struct AgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PeeringAgents", provider: AgentsProvider()) { entry in
            AgentsEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agents")
        .description("See which chat is working, which is waiting on you, and the step it is on.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

/// A second entry ten minutes out so a list the app stopped refreshing (it was closed) reads as old rather than live.
private struct AgentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgentsEntry {
        AgentsEntry(date: Date(), chats: [], updatedAt: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentsEntry) -> Void) {
        completion(current(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentsEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [current(at: now), current(at: now.addingTimeInterval(600))], policy: .never))
    }

    private func current(at date: Date) -> AgentsEntry {
        let chats = SharedStore.agentChats
        return AgentsEntry(date: date, chats: chats, updatedAt: chats.map(\.updatedAt).max())
    }
}

private struct AgentsEntry: TimelineEntry {
    let date: Date
    let chats: [AgentChatSnapshot]
    let updatedAt: Date?

    var waiting: Int { chats.filter { $0.state == .needsYou }.count }
    var working: Int { chats.filter { $0.state == .working }.count }
    var isStale: Bool { updatedAt.map { date.timeIntervalSince($0) > 600 } ?? false }
}

private struct AgentsEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgentsEntry

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        default: small
        }
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            if let top = entry.chats.first {
                Text(top.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(line(for: top))
                    .font(.caption)
                    .foregroundStyle(tint(for: top).opacity(top.state == .needsYou ? 1 : 0.7))
                    .lineLimit(2)
                if top.hasUnfinishedPlan, !entry.isStale {
                    PlanSegments(done: top.planDone, total: top.planTotal)
                        .padding(.top, 2)
                }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(entry.chats.first?.url ?? Self.openURL)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if entry.chats.isEmpty {
                Spacer(minLength: 0)
                empty
                Spacer(minLength: 0)
            } else {
                // Three rows: a fourth shrinks them past readability.
                ForEach(entry.chats.prefix(3)) { chat in
                    Link(destination: chat.url) { row(chat) }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func row(_ chat: AgentChatSnapshot) -> some View {
        HStack(spacing: 9) {
            Image(systemName: chat.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(chat.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(chat.folder)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if chat.hasUnfinishedPlan, !entry.isStale {
                    HStack(spacing: 6) {
                        PlanSegments(done: chat.planDone, total: chat.planTotal)
                            .frame(width: 54)
                        Text(planText(chat))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(line(for: chat))
                        .font(.system(size: 11))
                        .foregroundStyle(chat.state == .needsYou ? tint(for: chat) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Circle()
                .fill(tint(for: chat))
                .frame(width: 7, height: 7)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .medium))
            Text("Agents")
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
            if entry.waiting > 0 {
                Text("\(entry.waiting) waiting")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ActivityTone.pending.tint)
            } else if entry.working > 0 {
                Text("\(entry.working) working")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No chats")
                .font(.headline)
            Text("Start one from Mac terminals.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: entry.waiting > 0 ? "hand.raised.fill" : "sparkles")
                Text(summary)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 13))
            if let top = entry.chats.first {
                Text(top.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(top.hasUnfinishedPlan && !entry.isStale ? planText(top) : line(for: top))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No chats")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(entry.chats.first?.url ?? Self.openURL)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: entry.waiting > 0 ? "hand.raised.fill" : "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(entry.waiting > 0 ? entry.waiting : entry.chats.count)")
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
            }
        }
        .widgetURL(entry.chats.first?.url ?? Self.openURL)
    }

    // MARK: Words

    private var summary: String {
        if entry.waiting > 0 { return String(localized: "\(entry.waiting) waiting on you") }
        if entry.working > 0 { return String(localized: "\(entry.working) working") }
        return entry.chats.isEmpty ? String(localized: "Agents") : String(localized: "\(entry.chats.count) ready")
    }

    private func line(for chat: AgentChatSnapshot) -> String {
        if entry.isStale { return String(localized: "Open Peering to refresh") }
        switch chat.state {
        case .needsYou: return String(localized: "Waiting on you")
        case .working: return chat.activity ?? String(localized: "Working")
        case .ready: return String(localized: "Ready")
        case .failed: return String(localized: "Stopped with an error")
        }
    }

    private func planText(_ chat: AgentChatSnapshot) -> String {
        guard let number = chat.planStepNumber else { return String(localized: "\(chat.planDone) of \(chat.planTotal) done") }
        return String(localized: "Step \(number) of \(chat.planTotal)") + (chat.planStep.map { " · " + $0 } ?? "")
    }

    private func tint(for chat: AgentChatSnapshot) -> Color {
        switch chat.state {
        case .needsYou: ActivityTone.pending.tint
        case .failed: ActivityTone.lost.tint
        case .working: .white.opacity(0.9)
        case .ready: .white.opacity(0.35)
        }
    }

    /// With no chat to name, the tile opens the app on the last Mac, as the quick connect widget's does.
    private static let openURL = URL(string: "peering://connect") ?? URL(fileURLWithPath: "/")
}
