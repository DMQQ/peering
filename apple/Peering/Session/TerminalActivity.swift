@preconcurrency import ActivityKit
import Foundation
import PeeringKit
import os

private let activityLog = Logger(subsystem: "pl.dmq.peering", category: "terminal-activity")

/// A singleton: a second instance would hold a second handle to the same activity.
@MainActor
final class TerminalActivity {
    static let shared = TerminalActivity()

    private var activity: Activity<TerminalActivityAttributes>?

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.liveActivities) as? Bool ?? true
    }

    private init() {}

    func update(serverName: String, startedAt: Date?, shellCount: Int) {
        guard isEnabled else {
            end()
            return
        }
        guard shellCount > 0 else {
            end()
            return
        }
        let phase: TerminalActivityAttributes.Phase = startedAt != nil ? .live : .connecting
        let state = TerminalActivityAttributes.ContentState(
            phase: phase,
            serverName: serverName,
            startedAt: startedAt,
            shellCount: shellCount
        )
        apply(state)
    }

    /// Without this, an activity from a killed process keeps a running clock on the Lock Screen.
    func adoptOrphan() {
        guard activity == nil else { return }
        let orphans = Activity<TerminalActivityAttributes>.activities
        for orphan in orphans {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
        guard !orphans.isEmpty else { return }
        activityLog.info("ended \(orphans.count) terminal Live Activit\(orphans.count == 1 ? "y" : "ies") left by a previous launch")
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func apply(_ state: TerminalActivityAttributes.ContentState) {
        guard let activity else {
            start(state)
            return
        }
        Task { await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state))) }
    }

    private func start(_ state: TerminalActivityAttributes.ContentState) {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: TerminalActivityAttributes(),
                content: ActivityContent(state: state, staleDate: staleDate(for: state)),
                pushType: nil
            )
        } catch {
            Analytics.failed(error, in: .liveActivity)
            activityLog.error("could not start terminal Live Activity: \(String(describing: error), privacy: .public)")
        }
    }

    private func staleDate(for state: TerminalActivityAttributes.ContentState) -> Date? {
        switch state.phase {
        case .connecting: return Date().addingTimeInterval(45)
        case .live: return nil
        }
    }
}
