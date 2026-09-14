import SwiftUI
import WidgetKit

/// A square that opens Peering ready to connect, and names the Mac it will connect to.
///
/// The tap does not connect anything by itself — it cannot. The session, the certificate identity
/// and the sockets all live in the app, and a widget is a separate process that is not allowed to
/// start one. What this really is, then, is a shorter way to the app: it opens to the session
/// rather than to a screen the user has to act on.
struct QuickConnectWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PeeringQuickConnect", provider: QuickConnectProvider()) { entry in
            QuickConnectTile(hostName: entry.hostName)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick connect")
        .description("Open Peering and connect to the Mac you used last.")
        .supportedFamilies([.systemSmall])
    }
}

/// The same tile every time, until the app says otherwise.
///
/// `.never`, because nothing here is a function of time — the only thing that changes it is the
/// app connecting to a different Mac, and the app reloads the timeline when it does. A schedule
/// would be a wake-up that always returns the same answer.
private struct QuickConnectProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickConnectEntry {
        QuickConnectEntry(date: Date(), hostName: "Your Mac")
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickConnectEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickConnectEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> QuickConnectEntry {
        QuickConnectEntry(date: Date(), hostName: SharedStore.lastHostName)
    }
}

private struct QuickConnectEntry: TimelineEntry {
    let date: Date
    let hostName: String?
}

private struct QuickConnectTile: View {
    let hostName: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "display")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.primary)

            // The Mac's name, or the app's own when there is nothing to name yet — a Mac has
            // never been connected to. Naming it is most of what makes this useful at a glance:
            // without it the tile says "connect" and leaves the user to remember to what.
            Text(hostName ?? "Peering")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Tap to connect")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "peering://connect"))
    }
}
