import SwiftUI
import WidgetKit

private enum HostWidgetStore {
    static let suiteName = "group.pl.dmq.peering"
    static let defaults = UserDefaults(suiteName: suiteName)

    static var isListening: Bool { defaults?.bool(forKey: "hostWidget.isListening") ?? false }
    static var deviceName: String { defaults?.string(forKey: "hostWidget.deviceName") ?? "This Mac" }
    static var connectedNames: [String] {
        defaults?.stringArray(forKey: "hostWidget.connectedNames") ?? []
    }
}

private struct HostWidgetEntry: TimelineEntry {
    let date: Date
    let isListening: Bool
    let deviceName: String
    let connectedNames: [String]
}

private struct HostWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> HostWidgetEntry {
        HostWidgetEntry(
            date: Date(),
            isListening: true,
            deviceName: "MacBook Pro",
            connectedNames: ["Damian's iPhone"]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (HostWidgetEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HostWidgetEntry>) -> Void) {
        let entry = current()
        completion(Timeline(
            entries: [entry],
            policy: .after(Date().addingTimeInterval(60))
        ))
    }

    private func current() -> HostWidgetEntry {
        HostWidgetEntry(
            date: Date(),
            isListening: HostWidgetStore.isListening,
            deviceName: HostWidgetStore.deviceName,
            connectedNames: HostWidgetStore.connectedNames
        )
    }
}

struct PeeringHostWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PeeringHostControl", provider: HostWidgetProvider()) { entry in
            HostWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.04, green: 0.04, blue: 0.045)
                }
        }
        .configurationDisplayName("Peering host")
        .description("Start or stop Peering and see connected devices.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct HostWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HostWidgetEntry

    var body: some View {
        if family == .systemMedium {
            medium
        } else {
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Spacer(minLength: 0)
            Text(statusTitle)
                .font(.system(size: 18, weight: .bold, design: .serif))
                .lineLimit(2)
            Text(deviceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            action
        }
    }

    private var medium: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                header
                Spacer(minLength: 0)
                Text(statusTitle)
                    .font(.system(size: 22, weight: .bold, design: .serif))
                Text(entry.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                action
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().overlay(.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                Text("Connected devices")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if entry.connectedNames.isEmpty {
                    Spacer(minLength: 0)
                    Text(entry.isListening ? "Waiting for a paired device" : "Host is stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(entry.connectedNames.prefix(3).enumerated()), id: \.offset) { _, name in
                        HStack(spacing: 7) {
                            Image(systemName: "iphone")
                                .foregroundStyle(.secondary)
                            Text(name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.connected.to.line.below")
            Text("PEERING")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1)
            Spacer(minLength: 0)
            Circle()
                .fill(entry.isListening ? Color.green : .white.opacity(0.25))
                .frame(width: 7, height: 7)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var action: some View {
        Link(destination: commandURL) {
            Label(entry.isListening ? "Stop host" : "Start host", systemImage: entry.isListening ? "stop.fill" : "play.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.isListening ? Color.primary : Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(entry.isListening ? Color.white.opacity(0.10) : Color.white, in: Capsule())
        }
    }

    private var statusTitle: String {
        if !entry.isListening { return "Host stopped" }
        if entry.connectedNames.isEmpty { return "Ready to connect" }
        return entry.connectedNames.count == 1 ? "1 device connected" : "\(entry.connectedNames.count) devices connected"
    }

    private var deviceSummary: String {
        entry.connectedNames.first ?? entry.deviceName
    }

    private var commandURL: URL {
        URL(string: "peering-host://\(entry.isListening ? "stop" : "start")")!
    }
}
