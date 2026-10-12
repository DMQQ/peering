@preconcurrency import ActivityKit
import Foundation
import RemoteCore

/// The push tokens of the phone's Live Activities, kept so they reach whichever Mac the card follows.
///
/// A token appears while the app may not have a ready session, so it is remembered and sent when a session is ready.
@MainActor
final class LiveActivityTokens {
    static let shared = LiveActivityTokens()

    /// A Debug build's tokens work only against the sandbox APNs; TestFlight and the App Store use production.
    private static let environment: PushEnvironment = {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }()

    private struct Held {
        var pushToken: String?
        var pushToStartToken: String?
    }

    private var held: [LiveActivityKind: Held] = [:]
    private var observing = false

    /// Where a changed token goes: the session the card follows. Set once by the session model.
    var deliver: ((ActivityTokenPayload) -> Void)?

    private init() {}

    func pushToken(_ token: Data?, for kind: LiveActivityKind) {
        held[kind, default: Held()].pushToken = token.map(LiveActivityPushSupport.hex)
        deliver?(payload(for: kind))
    }

    private func pushToStartToken(_ token: Data, for kind: LiveActivityKind) {
        held[kind, default: Held()].pushToStartToken = LiveActivityPushSupport.hex(token)
        deliver?(payload(for: kind))
    }

    /// The activity ended. The push-to-start token stays, so the Mac can still raise a new card; with neither token left the Mac is told there is nothing to push to.
    func activityEnded(_ kind: LiveActivityKind) {
        pushToken(nil, for: kind)
    }

    /// Everything known, for a session that has just become ready.
    func sendAll(to session: ClientSession?) {
        guard let session else { return }
        for kind in LiveActivityKind.allCases where held[kind] != nil {
            session.sendActivityToken(payload(for: kind))
        }
    }

    /// A Mac the card no longer follows is told to stop pushing to it.
    func release(_ session: ClientSession?) {
        guard let session else { return }
        for kind in LiveActivityKind.allCases where held[kind] != nil {
            session.sendActivityToken(ActivityTokenPayload(activity: kind, pushToken: nil, pushToStartToken: nil, environment: Self.environment))
        }
    }

    /// Watches the system for the tokens that let a server start a card, once per launch.
    func startObservingPushToStart() {
        guard !observing else { return }
        observing = true
        Task {
            for await token in Activity<SessionActivityAttributes>.pushToStartTokenUpdates {
                self.pushToStartToken(token, for: .session)
            }
        }
        Task {
            for await token in Activity<AgentChatActivityAttributes>.pushToStartTokenUpdates {
                self.pushToStartToken(token, for: .agentChat)
            }
        }
        // A card the Mac started arrives here, and its own token only through this.
        Task {
            for await activity in Activity<AgentChatActivityAttributes>.activityUpdates {
                AgentChatActivity.shared.adopt(activity)
            }
        }
    }

    private func payload(for kind: LiveActivityKind) -> ActivityTokenPayload {
        let tokens = held[kind] ?? Held()
        return ActivityTokenPayload(
            activity: kind,
            pushToken: tokens.pushToken,
            pushToStartToken: tokens.pushToStartToken,
            environment: Self.environment
        )
    }
}
