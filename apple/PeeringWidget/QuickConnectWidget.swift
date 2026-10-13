import SwiftUI
import WidgetKit

/// Opens Peering ready to connect, and names what it will connect to.
///
/// A tap does not connect anything: the session lives in the app and a widget cannot start one, so this opens to the session.
struct QuickConnectWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PeeringQuickConnect", provider: QuickConnectProvider()) { entry in
            QuickConnectEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick connect")
        .description("Open Peering and connect to one of your Macs.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// `.never`: only the app changes the list, and it reloads the timeline when it does.
private struct QuickConnectProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickConnectEntry {
        QuickConnectEntry(
            date: Date(),
            hostName: String(localized: "Your Mac"),
            macs: [.init(id: "placeholder", name: String(localized: "Your Mac"))],
            connectedMacIDs: [],
            activeMacID: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickConnectEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickConnectEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> QuickConnectEntry {
        QuickConnectEntry(
            date: Date(),
            hostName: SharedStore.lastHostName,
            macs: SharedStore.knownMacs,
            connectedMacIDs: SharedStore.connectedMacIDs,
            activeMacID: SharedStore.activeMacID
        )
    }
}

private struct QuickConnectEntry: TimelineEntry {
    let date: Date
    let hostName: String?
    let macs: [SharedStore.KnownMac]

    /// Read from the shared container, so the widget never asks the app anything.
    let connectedMacIDs: [String]
    let activeMacID: String?
}

private struct QuickConnectEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickConnectEntry

    var body: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    private var small: some View {
        VStack(spacing: 6) {
            Image(systemName: "display")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.primary)

            Text(entry.hostName ?? "Peering")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Tap to connect")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole tile is the link; the medium size uses `Link` per row since its rows mean different Macs.
        .widgetURL(Self.connectURL(for: nil))
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "display")
                    .font(.system(size: 10, weight: .medium))
                Text("PEERING")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.0)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

            if entry.macs.isEmpty {
                Spacer(minLength: 0)
                Text("Pair a Mac and it appears here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                // Three rows: a fourth shrinks them past readability.
                ForEach(entry.macs.prefix(3)) { mac in
                    Link(destination: Self.connectURL(for: mac.id)) {
                        HStack(spacing: 8) {
                            Image(systemName: "macbook")
                                .font(.system(size: 13, weight: .medium))
                            Text(mac.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if entry.connectedMacIDs.contains(mac.id) {
                                Circle()
                                    .fill(entry.activeMacID == mac.id ? Color.green : Color.green.opacity(0.35))
                                    .frame(width: 7, height: 7)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The URL carries which Mac was asked for (see `onOpenURL` in `PeeringApp`); no id means the last one used.
    private static func connectURL(for id: String?) -> URL {
        var components = URLComponents()
        components.scheme = "peering"
        components.host = "connect"
        if let id {
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        }
        // Literals, so this cannot fail; the fallback exists because `URLComponents.url` is optional and `!` in a widget crashes the home screen.
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
