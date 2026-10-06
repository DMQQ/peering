@preconcurrency import ActivityKit
import Foundation
import MacCastKit
import os

private let activityLog = Logger(subsystem: "pl.dmq.peering", category: "agent-activity")

/// One card for all the chats: it exists while any of them is working or waiting on the person, and shows the one that matters most.
@MainActor
final class AgentChatActivity {
    static let shared = AgentChatActivity()

    private var activity: Activity<AgentChatActivityAttributes>?

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.liveActivities) as? Bool ?? true
    }

    private init() {}

    func update(chats: [AgentChatSnapshot]) {
        let busy = chats.filter { $0.state == .working || $0.state == .needsYou }
        guard isEnabled, let top = AgentChatSnapshot.ordered(busy).first else {
            end()
            return
        }
        let state = AgentChatActivityAttributes.ContentState(
            chat: top,
            waiting: busy.filter { $0.state == .needsYou }.count,
            working: busy.filter { $0.state == .working }.count
        )
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            start(state)
        }
    }

    /// Without this, an activity from a killed process keeps showing a chat that is no longer running.
    func adoptOrphan() {
        guard activity == nil else { return }
        for orphan in Activity<AgentChatActivityAttributes>.activities {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func start(_ state: AgentChatActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: AgentChatActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            activityLog.error("could not start agent Live Activity: \(String(describing: error), privacy: .public)")
        }
    }
}
