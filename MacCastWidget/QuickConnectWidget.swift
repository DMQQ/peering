import SwiftUI
import WidgetKit

/// Opens Peering ready to connect, and names what it will connect to.
///
/// A tap does not connect anything by itself — it cannot. The session, the certificate identity
/// and the sockets all live in the app, and a widget is a separate process that is not allowed to
/// start one. What this really is, then, is a shorter way in: it opens to the session rather than
/// to a screen the user has to act on.
///
/// Two sizes, because they answer different questions. Small names the Mac last used — one tap
/// and you are back where you were. Medium lists the Macs this phone has paired with, for the
/// case the small size cannot serve at all: more than one of them, and a choice to make.
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

/// The same list every time, until the app says otherwise.
///
/// `.never`, because nothing here is a function of time — the only thing that changes it is the
/// app pairing, forgetting or renaming a Mac, and the app reloads the timeline when it does. A
/// schedule would be a wake-up that always returns the same answer.
private struct QuickConnectProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickConnectEntry {
        QuickConnectEntry(
            date: Date(),
            hostName: "Your Mac",
            macs: [.init(id: "placeholder", name: "Your Mac")]
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
            macs: SharedStore.knownMacs
        )
    }
}

private struct QuickConnectEntry: TimelineEntry {
    let date: Date
    let hostName: String?
    let macs: [SharedStore.KnownMac]
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

            // The Mac's name, or the app's own when there is nothing to name yet — a Mac has
            // never been connected to. Naming it is most of what makes this useful at a glance:
            // without it the tile says "connect" and leaves the user to remember to what.
            Text(entry.hostName ?? "Peering")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Tap to connect")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole tile, so a tap anywhere works. The medium size cannot do this — its rows
        // mean different Macs — which is why it uses `Link` per row instead.
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
                // Three, and the rest scroll past silently. A widget is a glance, not a list,
                // and a fourth row shrinks every one of them past the point of being read at
                // arm's length. The app is one tap away and has room for all of them.
                ForEach(entry.macs.prefix(3)) { mac in
                    Link(destination: Self.connectURL(for: mac.id)) {
                        HStack(spacing: 8) {
                            Image(systemName: "macbook")
                                .font(.system(size: 13, weight: .medium))
                            Text(mac.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Where a tap goes.
    ///
    /// A widget cannot start a session, so the URL carries which Mac was asked for and the app
    /// does the rest — see the `onOpenURL` handler in `MacCastApp`. With no id it means "the one
    /// I used last", which is what a small tile has to mean.
    private static func connectURL(for id: String?) -> URL {
        var components = URLComponents()
        components.scheme = "peering"
        components.host = "connect"
        if let id {
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        }
        // The scheme and host are literals, so this cannot fail; the fallback is here because
        // `URLComponents.url` is optional and a `!` in a widget is a crash on the home screen.
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
