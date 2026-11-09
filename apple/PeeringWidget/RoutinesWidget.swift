import SwiftUI
import WidgetKit

/// Scheduled agent runs: which is running now, how the last one ended, and when the next starts.
struct RoutinesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PeeringRoutines", provider: RoutinesProvider()) { entry in
            RoutinesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Routines")
        .description("Running and last results of your scheduled agent runs.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}

private struct RoutinesProvider: TimelineProvider {
    func placeholder(in context: Context) -> RoutinesEntry { RoutinesEntry(date: Date(), routines: []) }

    func getSnapshot(in context: Context, completion: @escaping (RoutinesEntry) -> Void) {
        completion(RoutinesEntry(date: Date(), routines: SharedStore.routines))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RoutinesEntry>) -> Void) {
        completion(Timeline(entries: [RoutinesEntry(date: Date(), routines: SharedStore.routines)], policy: .never))
    }
}

private struct RoutinesEntry: TimelineEntry {
    let date: Date
    let routines: [SharedStore.RoutineSummary]
}

private struct RoutinesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RoutinesEntry

    var body: some View {
        if family == .accessoryRectangular { rectangular } else { medium }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Routines").font(.headline)
            if let top = entry.routines.first {
                Text(top.name).font(.caption).lineLimit(1)
                Text(status(top)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("None yet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "peering://connect"))
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Routines").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if entry.routines.isEmpty {
                Spacer(minLength: 0)
                Text("Open Agents and add a routine to run an agent while you are away.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.routines.prefix(3)) { routine in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(routine.outcome == .running ? WidgetTint.state : .white.opacity(0.3))
                            .frame(width: 7, height: 7)
                        Text(routine.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(status(routine)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func status(_ routine: SharedStore.RoutineSummary) -> String {
        guard routine.isEnabled else { return String(localized: "Off") }
        switch routine.outcome {
        case .running: return String(localized: "Running")
        case .failed: return String(localized: "Failed")
        case .stopped: return String(localized: "Stopped")
        case .skipped: return String(localized: "Skipped")
        case .succeeded, .neverRun:
            guard let next = routine.nextRunAt else { return routine.outcome == .succeeded ? String(localized: "Done") : String(localized: "Not run yet") }
            return String(localized: "Next \(next.formatted(.relative(presentation: .named)))")
        }
    }
}
