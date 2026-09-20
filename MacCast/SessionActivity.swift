// `@preconcurrency`, and it is load-bearing rather than decorative.
//
// ActivityKit's `Activity` is a class Apple does not mark `Sendable`, while its `update` and `end`
// are `@concurrent`. That combination means every call below sends a non-Sendable reference off
// the main actor, and Swift 6 rejects all five of them without this. The framework cannot be
// corrected from here; this is the escape hatch for a dependency that has not been annotated yet,
// and it keeps the calls compiling without claiming anything about `Activity` that is not true.
@preconcurrency import ActivityKit
import Foundation
import MacCastKit
import RemoteCore
import os

private let activityLog = Logger(subsystem: "pl.dmq.peering", category: "activity")

/// Starts, updates and ends the Live Activity that mirrors the session.
///
/// A singleton for the same reason ``SessionNotifier`` is one: a Live Activity belongs to the
/// app rather than to an object. A second instance would hold a second handle to the same
/// activity and the two would take turns overwriting each other.
@MainActor
final class SessionActivity {
    static let shared = SessionActivity()

    private var activity: Activity<SessionActivityAttributes>?

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.liveActivities) as? Bool ?? true
    }

    private init() {}

    /// The one entry point, called beside the notifier on every phase change.
    func sessionMoved(
        from previous: ClientSession.Phase,
        to phase: ClientSession.Phase,
        hostName: String,
        startedAt: Date?,
        reconnecting: Bool,
        deliberate: Bool = false,
        path: SessionActivityAttributes.Path? = nil
    ) {
        guard isEnabled else {
            end()
            return
        }
        guard previous != phase else { return }

        // A dropped session is put back on its own, and the card should say so rather than
        // disappear for the forty seconds the retries take — see ``showReconnecting(hostName:)``.
        if reconnecting, !phase.holdsSession {
            show(.reconnecting, hostName: hostName, startedAt: startedAt, path: path)
            return
        }

        switch phase {
        case .connecting, .handshaking, .confirming, .ready:
            let state = SessionActivityAttributes.ContentState(
                phase: phase == .ready ? .active : .pending,
                startedAt: startedAt,
                path: path
            )
            if let activity {
                Task { await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state))) }
            } else {
                // Only ever reached from the foreground: every route into these phases starts
                // with a tap, and `Activity.request` is dropped silently from the background.
                start(attributes: SessionActivityAttributes(hostName: hostName), state: state)
            }

        case .idle, .failed, .disconnected:
            // Only a deliberate end takes the card down. The user closed the session; a card
            // offering to put back what they just shut is arguing with them.
            //
            // Everything else used to remove it too, and that was wrong in both directions: a
            // card that vanishes says nothing about what happened, and the moment the card is
            // most useful — the connection has gone, would you like it back — is the moment it
            // was being taken away.
            if deliberate {
                end()
            } else {
                show(.dropped, hostName: hostName, startedAt: startedAt, path: path)
            }
        }
    }

    /// Ends the card outright.
    ///
    /// Reached separately from ``sessionMoved(from:to:hostName:startedAt:reconnecting:)``
    /// because a deliberate disconnect does not travel through it. `SessionModel.disconnect`
    /// sets the phase itself — it has to, so the screen leaves the session the instant it is
    /// tapped — and the announcement `ClientSession` then makes carries the phase the model has
    /// *already* moved to. `sessionMoved` treats a phase that has not changed as nothing to do,
    /// which is right in general and was wrong here: the card the user had just dismissed by
    /// quitting was left running on the Lock Screen, claiming a session that was over.
    func sessionEnded() {
        end()
    }

    /// Puts a card up saying the session dropped and is being put back.
    ///
    /// `startedAt` is carried through so the clock does not restart: the session being recovered
    /// is the same one, and a duration that began again at the drop would be describing a
    /// reconnect as a new connection.
    func showReconnecting(
        hostName: String,
        startedAt: Date?,
        path: SessionActivityAttributes.Path? = nil
    ) {
        guard isEnabled else { return }
        show(.reconnecting, hostName: hostName, startedAt: startedAt, path: path)
    }

    /// The session was lost rather than ended, and the card stays up to say so.
    ///
    /// Its own entry point because the caller is not a phase change: `SessionModel.disconnect`
    /// is how both a tapped quit and an end forced by iOS arrive, and only the first of those
    /// should take the card down.
    func sessionDropped(
        hostName: String,
        startedAt: Date?,
        path: SessionActivityAttributes.Path? = nil
    ) {
        guard isEnabled else { return }
        show(.dropped, hostName: hostName, startedAt: startedAt, path: path)
    }

    /// Applies the Settings switch immediately. Enabling takes effect on the next connection;
    /// disabling also removes a card that is already on the Lock Screen.
    func preferenceChanged(enabled: Bool) {
        if !enabled { end() }
    }

    /// Shows a state that is about the session rather than being it.
    ///
    /// The two — dropped and reconnecting — differ only in which phase they set, and both are
    /// reached at moments when the card must *stay up*, which is the whole reason they are not
    /// a switch over `ClientSession.Phase`.
    private func show(
        _ phase: SessionActivityAttributes.Phase,
        hostName: String,
        startedAt: Date?,
        path: SessionActivityAttributes.Path?
    ) {
        let state = SessionActivityAttributes.ContentState(
            phase: phase,
            startedAt: startedAt,
            path: path
        )
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state))) }
        } else {
            start(attributes: SessionActivityAttributes(hostName: hostName), state: state)
        }
    }

    /// Called when the app enters the background with an active session.
    ///
    /// Stamps a stale date on the running card so that if the process is killed before the
    /// background-task window expires — a force-quit from the app switcher, for instance —
    /// the Lock Screen card grays out automatically rather than sitting there indefinitely
    /// claiming an active connection that has been gone since the user swiped away.
    func enteringBackground() {
        guard let activity, activity.activityState == .active else { return }
        let state = activity.content.state
        Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))) }
    }

    /// Called when the app returns to the foreground. Lifts the stale-date imposed by
    /// ``enteringBackground()`` so the card looks live again while the session continues.
    func returningToForeground() {
        guard let activity, activity.activityState == .active else { return }
        let state = activity.content.state
        Task { await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state))) }
    }

    /// Takes down an activity left behind by a previous run of the app.
    ///
    /// Without this, an activity started before the process was killed keeps a running clock on
    /// the Lock Screen for a session that ended hours ago, and this launch would have no idea it
    /// was there to remove — the handle is nil after a relaunch, which is the only way back to it.
    func adoptOrphan() {
        guard activity == nil, let orphan = Activity<SessionActivityAttributes>.activities.first else { return }
        activityLog.info("adopting a Live Activity left by a previous launch")
        activity = orphan
        end()
    }

    private func start(
        attributes: SessionActivityAttributes,
        state: SessionActivityAttributes.ContentState
    ) {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: staleDate(for: state)),
                // Local only. Every update here is produced in-process on a phase change, so a
                // push token would be a standing promise to a server that does not exist.
                pushType: nil
            )
        } catch {
            activityLog.error("could not start the Live Activity: \(String(describing: error), privacy: .public)")
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// When the system should re-render this without being told to.
    ///
    /// A live session passes `nil`: marking a genuinely running session stale puts the dimmed
    /// "not updating" treatment on the one state that is certainly still true. A pending one
    /// gets a deadline instead, so a connect that hangs stops looking like progress.
    private func staleDate(for state: SessionActivityAttributes.ContentState) -> Date? {
        // Both of these are waiting on something that could hang, and neither should be able to
        // sit there looking like progress forever.
        switch state.phase {
        case .pending, .reconnecting: return Date().addingTimeInterval(45)
        case .active: return nil
        // No deadline: a dropped session does not become less true by waiting, and the card is
        // the only route back to it. The system retires it on its own after a few hours.
        case .dropped: return nil
        }
    }
}
