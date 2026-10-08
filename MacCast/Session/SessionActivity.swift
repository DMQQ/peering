// `@preconcurrency` is load-bearing: ActivityKit's `Activity` is not `Sendable` while `update` and `end` are `@concurrent`, so Swift 6 rejects every call without it.
@preconcurrency import ActivityKit
import Foundation
import MacCastKit
import RemoteCore
import os

private let activityLog = Logger(subsystem: "pl.dmq.peering", category: "activity")

/// A singleton like ``SessionNotifier``: a second instance would hold a second handle to the same activity and they would overwrite each other.
@MainActor
final class SessionActivity {
    static let shared = SessionActivity()

    private var activity: Activity<SessionActivityAttributes>?

    private var current: SessionActivityAttributes.ContentState?

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.liveActivities) as? Bool ?? true
    }

    private init() {}

    func sessionMoved(
        from previous: ClientSession.Phase,
        to phase: ClientSession.Phase,
        hostName: String,
        startedAt: Date?,
        reconnecting: Bool,
        deliberate: Bool = false,
        path: SessionActivityAttributes.Path? = nil,
        sessionCount: Int? = nil
    ) {
        guard isEnabled else {
            end()
            return
        }
        guard previous != phase else { return }

        // A dropped session is put back on its own; the card says so rather than disappearing for the forty seconds the retries take.
        if reconnecting, !phase.holdsSession {
            show(.reconnecting, hostName: hostName, startedAt: startedAt, path: path)
            return
        }

        switch phase {
        case .connecting, .handshaking, .confirming, .ready:
            // Only from the foreground: `Activity.request` is dropped silently from the background.
            apply(carryingWork(SessionActivityAttributes.ContentState(
                phase: phase == .ready ? .active : .pending,
                startedAt: startedAt,
                path: path,
                hostName: hostName,
                sessionCount: sessionCount
            )))

        case .idle, .failed, .disconnected:
            // Only a deliberate end takes the card down: a card offering to put back what the user just shut is arguing with them, and a dropped session is when the card is most useful.
            if deliberate {
                end()
            } else {
                show(.dropped, hostName: hostName, startedAt: startedAt, path: path)
            }
        }
    }

    /// A deliberate disconnect does not travel through `sessionMoved`: `SessionModel.disconnect` sets the phase itself, so the announcement carries an unchanged phase, which `sessionMoved` ignores. Without this the card stayed on the Lock Screen after a quit.
    func sessionEnded() {
        end()
    }

    /// `startedAt` is carried through so the clock does not restart on a reconnect.
    func showReconnecting(
        hostName: String,
        startedAt: Date?,
        path: SessionActivityAttributes.Path? = nil,
        sessionCount: Int? = nil
    ) {
        guard isEnabled else { return }
        show(.reconnecting, hostName: hostName, startedAt: startedAt, path: path, sessionCount: sessionCount)
    }

    /// Its own entry point: `SessionModel.disconnect` serves both a tapped quit and an end forced by iOS, and only the first takes the card down.
    func sessionDropped(
        hostName: String,
        startedAt: Date?,
        path: SessionActivityAttributes.Path? = nil,
        sessionCount: Int? = nil
    ) {
        guard isEnabled else { return }
        show(.dropped, hostName: hostName, startedAt: startedAt, path: path, sessionCount: sessionCount)
    }

    func preferenceChanged(enabled: Bool) {
        if !enabled { end() }
    }

    /// Not a phase change, so it cannot go through `sessionMoved`: that ignores a seen phase, and a tab switch changes everything but the phase.
    /// The clock restarts from the new Mac's own `sessionStartedAt`, not carried over from the Mac left.
    func followActiveSession(
        hostName: String,
        startedAt: Date?,
        phase: ClientSession.Phase,
        reconnecting: Bool,
        path: SessionActivityAttributes.Path?,
        sessionCount: Int
    ) {
        guard isEnabled else { return }
        guard let activity else { return }
        let state = carryingWork(SessionActivityAttributes.ContentState(
            phase: Self.cardPhase(of: phase, reconnecting: reconnecting),
            startedAt: startedAt,
            path: path,
            hostName: hostName,
            sessionCount: sessionCount
        ))
        current = state
        Task { await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state))) }
    }

    /// Shells and chats come and go without the session moving. Ignored when nothing changed, so a chatty terminal does not re-render the card per keystroke.
    func workChanged(_ work: [SessionActivityAttributes.ContentState.Work]) {
        guard isEnabled, var state = current, state.work != work else { return }
        state.work = work
        current = state
        guard let activity, activity.activityState == .active else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state))) }
    }

    /// A session still connecting is `pending`; a Mac being put back is `reconnecting` because its phase during a retry is `.failed`.
    static func cardPhase(
        of phase: ClientSession.Phase,
        reconnecting: Bool
    ) -> SessionActivityAttributes.Phase {
        if reconnecting, !phase.holdsSession { return .reconnecting }
        switch phase {
        case .ready: return .active
        case .idle, .connecting, .handshaking, .confirming: return .pending
        case .failed, .disconnected: return .dropped
        }
    }

    private func show(
        _ phase: SessionActivityAttributes.Phase,
        hostName: String,
        startedAt: Date?,
        path: SessionActivityAttributes.Path?,
        sessionCount: Int? = nil
    ) {
        apply(carryingWork(SessionActivityAttributes.ContentState(
            phase: phase,
            startedAt: startedAt,
            path: path,
            hostName: hostName,
            sessionCount: sessionCount
        )))
    }

    /// The work list lives in its own field and would be emptied by every phase change if each site had to remember it.
    private func carryingWork(
        _ state: SessionActivityAttributes.ContentState
    ) -> SessionActivityAttributes.ContentState {
        var state = state
        state.work = current?.work
        return state
    }

    /// Stamps a stale date so a force-quit before the background window expires greys the card out instead of claiming a dead connection.
    func enteringBackground() {
        guard let activity, activity.activityState == .active else { return }
        let state = activity.content.state
        Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))) }
    }

    func returningToForeground() {
        guard let activity, activity.activityState == .active else { return }
        let state = activity.content.state
        Task { await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state))) }
    }

    /// The handle is nil after a relaunch, so an activity from a killed run would keep its clock on the Lock Screen.
    func adoptOrphan() {
        guard activity == nil else { return }
        // All of them, not the first: more than one means an earlier run went wrong, and the rest would sit there for the system's eight hours.
        let orphans = Activity<SessionActivityAttributes>.activities
        for orphan in orphans {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
        guard !orphans.isEmpty else { return }
        activityLog.info("ended \(orphans.count) Live Activit\(orphans.count == 1 ? "y" : "ies") left by a previous launch")
    }

    private func apply(_ state: SessionActivityAttributes.ContentState) {
        current = state
        guard let activity else {
            start(state)
            return
        }
        Task { await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state))) }
    }

    private func start(_ state: SessionActivityAttributes.ContentState) {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        current = state
        do {
            activity = try Activity.request(
                // No attributes: everything varies in the state, so a card can be re-pointed at another Mac.
                attributes: SessionActivityAttributes(),
                content: ActivityContent(state: state, staleDate: staleDate(for: state)),
                // Local only: a push token would be a promise to a server that does not exist.
                pushType: nil
            )
        } catch {
            Analytics.failed(error, in: .liveActivity)
            activityLog.error("could not start the Live Activity: \(String(describing: error), privacy: .public)")
        }
    }

    private func end() {
        guard let activity else { return }
        current = nil
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// A live session passes `nil`: marking it stale dims the one state certainly still true. A pending one gets a deadline so a hung connect stops looking like progress.
    private func staleDate(for state: SessionActivityAttributes.ContentState) -> Date? {
        switch state.phase {
        case .pending, .reconnecting: return Date().addingTimeInterval(45)
        case .active: return nil
        // No deadline: a dropped session does not become less true by waiting, and the card is the only route back.
        case .dropped: return nil
        }
    }
}
