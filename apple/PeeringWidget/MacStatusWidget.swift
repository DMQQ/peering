import SwiftUI
import WidgetKit

/// Which of your Macs this phone has open right now, so a glance says whether a session is up.
struct MacStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PeeringMacStatus", provider: MacStatusProvider()) { entry in
            MacStatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Mac status")
        .description("Shows whether your Macs are connected.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

private struct MacStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacStatusEntry { MacStatusEntry(date: Date(), macs: [], connected: []) }

    func getSnapshot(in context: Context, completion: @escaping (MacStatusEntry) -> Void) { completion(current()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacStatusEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> MacStatusEntry {
        MacStatusEntry(date: Date(), macs: SharedStore.knownMacs, connected: Set(SharedStore.connectedMacIDs))
    }
}

private struct MacStatusEntry: TimelineEntry {
    let date: Date
    let macs: [SharedStore.KnownMac]
    let connected: Set<String>

    var connectedMacs: [SharedStore.KnownMac] { macs.filter { connected.contains($0.id) } }
}

private struct MacStatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MacStatusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: entry.connectedMacs.isEmpty ? "macbook.slash" : "macbook")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "macbook").foregroundStyle(entry.connectedMacs.isEmpty ? .secondary : WidgetTint.state)
                Spacer(minLength: 0)
                Text(headline).font(.headline).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(URL(string: "peering://connect"))
        }
    }

    private var headline: String {
        entry.connectedMacs.isEmpty ? String(localized: "Not connected") : String(localized: "Connected")
    }

    private var detail: String {
        if let first = entry.connectedMacs.first {
            entry.connectedMacs.count > 1 ? String(localized: "\(first.name) and \(entry.connectedMacs.count - 1) more") : first.name
        } else {
            entry.macs.first?.name ?? String(localized: "No Mac paired")
        }
    }
}
