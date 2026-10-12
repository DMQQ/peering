@preconcurrency import ActivityKit
import Foundation
import MacCastKit
import RemoteCore
import os

private let activityLog = Logger(subsystem: "pl.dmq.peering", category: "agent-activity")

/// One card for all the chats: it exists while any of them is open, and shows the one that matters most.
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
        // Kept while any chat is open: one that has finished stays on the card, a tap from picking it up.
        guard isEnabled, let top = AgentChatSnapshot.ordered(chats).first else {
            end()
            return
        }
        let state = AgentChatActivityAttributes.ContentState(
            chat: top,
            waiting: busy.filter { $0.state == .needsYou }.count,
            working: busy.filter { $0.state == .working }.count,
            hostKey: top.hostID.map(HostKey.of)
        )
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            start(state)
        }
    }

    /// A card from a killed process, or one the Mac started with a push, is taken over rather than ended: the next update rewrites it, and ends it when no chat is left.
    func adoptOrphan() {
        for card in Activity<AgentChatActivityAttributes>.activities { adopt(card) }
    }

    func adopt(_ card: Activity<AgentChatActivityAttributes>) {
        guard card.activityState == .active else { return }
        if let activity, activity.id != card.id {
            Task { await card.end(nil, dismissalPolicy: .immediate) }
            return
        }
        activity = card
        observe(card)
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Passes the card's push token to the Mac, and notices when the Mac, the system or the user ends it so the handle does not block the next card.
    private func observe(_ card: Activity<AgentChatActivityAttributes>) {
        Task {
            for await token in card.pushTokenUpdates {
                LiveActivityTokens.shared.pushToken(token, for: .agentChat)
            }
        }
        Task {
            for await state in card.activityStateUpdates where state == .ended || state == .dismissed {
                if activity?.id == card.id { activity = nil }
                if activity == nil { LiveActivityTokens.shared.activityEnded(.agentChat) }
                return
            }
        }
    }

    private func start(_ state: AgentChatActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: AgentChatActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: .token
            )
            if let activity { observe(activity) }
        } catch {
            Analytics.failed(error, in: .liveActivity)
            activityLog.error("could not start agent Live Activity: \(String(describing: error), privacy: .public)")
        }
    }
}
