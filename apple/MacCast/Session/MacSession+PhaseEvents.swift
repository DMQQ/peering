import MacCastKit
import RemoteCore
import SwiftUI

extension MacSession {
    func apply(phase: ClientSession.Phase) {
        CrashLog.note("phase \(phase) · \(hostID ?? "unknown")\(isReconnecting ? " (reconnecting)" : "")")
        var shouldScheduleReconnect = true
        if case .failed = phase, model.isResuming {
            switch settleFailedResume() {
            case .retried:
                return
            case .showFailure:
                shouldScheduleReconnect = false
            }
        }
        if phase.holdsSession {
            model.isResuming = false
            // A session that is up again is a resume that arrived; without this the next drop would be the tail of the last one, with the shorter ladder already spent.
            hasGivenUpResuming = false
        }

        // Read before the assignment: what is said about a transition is about where the session came from as well as where it landed.
        let previous = self.phase
        if previous == .ready, phase != .ready { noteLeavingReady() }
        let cappedFailure = previous == .ready ? retryCapFailure(for: phase) : nil
        if previous == .ready, case .failed = phase { noteDropped(capped: cappedFailure != nil) }
        if cappedFailure != nil { shouldScheduleReconnect = false }
        failureCause = cappedFailure == nil ? wire?.failureCause : nil
        self.phase = cappedFailure ?? FailureText.localized(phase, cause: failureCause)

        if phase == .ready { announceReady() }
        if case .failed(let message) = phase {
            reportConnectFailure(appState: Analytics.name(of: UIApplication.shared.applicationState))
            videoStatus = String(localized: "Stopped: \(HostWireText.localized(message))")
        }
        if phase == .disconnected {
            videoStatus = String(localized: "Disconnected")
        }
        if phase == .ready {
            recordReady(previous: previous)
        } else {
            sessionStartedAt = nil
        }

        // This Mac's own answer, kept on the record rather than cleared here: everything asking whether a session is being put back reads it a moment later, and clearing it left a Quit showing reconnecting. Every attempt is a new session object, so nothing needs it cleared. See ``MacSession/userEndedDeliberately``.
        let userEnded = userEndedDeliberately
        // A session that ended without the user asking is put back on its own; the flag inside `scheduleReconnect` decides, since the phase cannot tell a drop from a disconnect. Before the activity is told, since scheduling sets `isReconnecting` and the card must say reconnecting, and before the banner, whose question is whether the drop is already being put back.
        if !phase.holdsSession, !userEnded, shouldScheduleReconnect {
            releaseFinishedWire()
            scheduleReconnect()
        }

        announce(from: previous, to: phase, userEnded: userEnded)

        if !phase.holdsSession { releaseLatchedModifiers() }
    }

    private enum FailedResume {
        case retried
        case showFailure
    }

    /// A failure during a resume is retried, not shown: when this Mac had reached Ready it is one step of the reconnect ladder (see ``SessionModel/isResuming``). A cold-launch restoration's first failure is terminal, shown once, and clears the persisted request.
    private func settleFailedResume() -> FailedResume {
        model.isResuming = false
        let failedReason = wire?.failureReason
        // The attempt is over: `resumeIfNeeded` refuses to start while a wire is held, which is true from `connect(to:)` until the attempt fails.
        connectTask?.cancel()
        connectTask = nil
        wire = nil
        switch SessionResume.failureAction(hasBeenReady: hasBeenReady, reason: failedReason) {
        case .retrySilently:
            scheduleReconnect()
            return .retried
        case .stopAndShowFailure:
            UserDefaults.standard.set(false, forKey: SessionModel.resumeKey)
            // Nothing will dial this Mac again, so it stops being one the app is putting back; left set, the failure would be shown under a header still saying reconnecting.
            isComingBack = false
            return .showFailure
        }
    }

    private func noteLeavingReady() {
        // Read before `finishSessionHistory()` and the teardown below, both of which take a piece of it. Only a relay session ending without the user ending it is recorded (``SessionModel/relaySessionDropped``); a LAN drop is not, since the relay cannot have cut it. Read from this Mac's own record because the flag below is cleared on the way past (``MacSession/userEndedDeliberately``).
        if !userEndedDeliberately, connectionPath == .relay {
            model.relaySessionDropped = true
        }
        closeStretch()
        finishSessionHistory()
    }

    private func announceReady() {
        model.pairedHostIDs = model.pins.hostIDs
        // A handshake reaching `.ready` has just established or confirmed a pin, one of the few moments the paired list can change.
        model.publishKnownMacs()
        // Also when this Mac's own ID becomes known, which the widget's list is keyed by. See ``SessionModel/publishOpenMacs()``.
        model.publishOpenMacs()
        applyInitialQuality()
        wire?.sendTerminal(.list)
        refreshAgentSessions()
        // Every arrival at `.ready`: the Mac keeps a scope only for the connection that made it, so a reconnect must announce this phone's id again.
        openFileScope()
        model.sendPushToken()
        // Every arrival at `.ready`, a reconnect included: the Mac on the other end has no memory of the one before. See ``pendingSourceReassertion``.
        pendingSourceReassertion = true
    }

    private func recordReady(previous: ClientSession.Phase) {
        // Read before the line below overwrites it: `hasBeenReady` tells a reconnect from a connection, which decides whether the record a drop filed is continued or a new one started. The value is the one the ladder carried onto this object (see ``SessionModel/connect(to:replacing:)``).
        let hadBeenReady = hasBeenReady
        hasBeenReady = true
        // Cleared so a drop followed by a working reconnect cannot label a refusal an hour later as the relay cutting something.
        model.relaySessionDropped = false
        // Restarted on every arrival: a reconnect emits `.ready` again, and elapsed time kept counting through it would describe a session that no longer exists.
        guard previous != .ready else { return }
        model.reconnectAttempt = 0
        // The episode is over, so its clock goes with it: kept, the next drop would be judged against an expired window.
        reconnectingSince = nil
        sessionStartedAt = Date()
        noteReady(hadBeenReady: hadBeenReady)
        beginSessionHistory(resuming: hadBeenReady)
        UserDefaults.standard.set(true, forKey: SessionModel.resumeKey)
        if let id = hostID {
            model.lastConnectedAt[id] = Date()
            if let data = try? JSONEncoder().encode(model.lastConnectedAt) {
                UserDefaults.standard.set(data, forKey: "hostLastConnectedAt")
            }
        }
    }

    /// Released here, or the ladder cannot take a single step: `resumeIfNeeded` guards on `session == nil`, and neither `disconnect()` nor `connect(to:)` runs when a session drops on its own, so the first tick saw a session, called `stopReconnecting`, and nothing re-armed. The object is finished with: `ClientSession.fail` cancels the control connection, video socket, datagram lane and relay proxy before emitting this phase.
    private func releaseFinishedWire() {
        connectTask?.cancel()
        connectTask = nil
        wire = nil
    }

    private func announce(from previous: ClientSession.Phase, to phase: ClientSession.Phase, userEnded: Bool) {
        // Every Mac, unlike the card: a banner is about a Mac the user is not looking at. Keyed by host so two Macs' banners queue rather than replace each other. See ``SessionAwareness/Notification/hostID``.
        model.notifier.sessionMoved(
            from: previous,
            to: phase,
            hostName: shownName ?? String(localized: "the Mac"),
            hostID: hostID,
            deliberate: userEnded,
            resuming: isResumingAfterDrop
        )
        // Held open as long as there is a session, so the socket outlives the app being on screen. Started before the card, which is worthless if its session was already suspended. See ``SessionAudio``.
        if phase.holdsSession {
            SessionAudio.shared.begin()
        } else {
            SessionAudio.shared.end()
        }

        // The card describes the Mac on screen only: there is one Activity for the app, so a background Mac's transition would take the card from the Mac the user is looking at. That news is a banner's job (``SessionNotifier``).
        if isActive {
            SessionActivity.shared.sessionMoved(
                from: previous,
                to: phase,
                hostName: shownName ?? String(localized: "the Mac"),
                startedAt: sessionStartedAt,
                reconnecting: isReconnecting,
                deliberate: userEnded,
                path: Self.activityPath(connectionPath)
            )
            if phase == .ready { LiveActivityTokens.shared.sendAll(to: wire) }
        }
    }

    private func releaseLatchedModifiers() {
        // The buttons stop claiming a modifier once its link is gone, since the release cannot travel back. The window server keeps the flag until a real key-up, so the Mac may still hold it, which is why this says so.
        if !model.latchedModifiers.isEmpty {
            append(note: String(localized: "The connection ended while \(model.latchedModifiers.label) was held on the Mac. It may still be held there."))
        }
        model.latchedModifiers = []
        privacyModeEnabled = false
    }
}
