import RemoteCore
import WidgetKit

/// Mirrors the Mac's routines into the shared container, since the widget is a process of its own that cannot ask.
enum RoutineWidgetPublisher {
    static func publish(_ routines: [AgentRoutine]) {
        let summaries = routines.map { routine in
            SharedStore.RoutineSummary(
                id: routine.id.uuidString,
                name: routine.name,
                outcome: outcome(of: routine.lastRun?.outcome),
                lastRunAt: routine.lastRun?.startedAt,
                nextRunAt: routine.nextRunAt,
                isEnabled: routine.isEnabled
            )
        }
        .sorted { ($0.outcome == .running ? 0 : 1) < ($1.outcome == .running ? 0 : 1) }
        guard summaries != SharedStore.routines else { return }
        SharedStore.routines = summaries
        WidgetCenter.shared.reloadTimelines(ofKind: "PeeringRoutines")
    }

    private static func outcome(of outcome: AgentRoutineRun.Outcome?) -> SharedStore.RoutineSummary.Outcome {
        switch outcome {
        case .none: .neverRun
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .stopped: .stopped
        case .skipped: .skipped
        }
    }
}
