import MacCastKit
import RemoteCore
import SwiftUI

extension SessionModel {
    // MARK: - Backgrounding

    func setPiPAutoStart(_ on: Bool) { SessionPiP.shared.autoStart = on }

    /// No background mode a remote desktop can honestly claim: this only buys the few seconds that make switching away and straight back survivable.
    func enteringBackground() {
        SessionActivity.shared.enteringBackground()

        // The Mac's detector fires once when the prompt appears and this side says nothing while the app is in front, so without this a prompt left open never reaches a banner.
        for session in sessions where session.phase == .ready {
            for terminal in session.terminals {
                guard let kind = terminal.attention else { continue }
                notifier.terminalStillWaiting(
                    kind,
                    name: terminal.name,
                    sessionID: terminal.id,
                    macName: session.hostName
                )
            }
        }

        // Started here, not left to `canStartPictureInPictureAutomaticallyFromInline`: iOS never takes the hint, since an `AVAudioPlayer` running silence does not count as playing.
        // The moment matters: as the app leaves the screen, `startPictureInPicture` still has a view hierarchy to lift the layer from.
        SessionPiP.shared.backgrounding(sessionIsUp: phase.holdsSession)

        beginBackgroundGrace()
    }

    /// First thing when the app stops being the active scene, before iOS freezes it with its sockets open: the Mac otherwise keeps encoding for a phone that cannot read it. The grace is requested first so the notice has time to leave.
    func leavingForeground() {
        beginBackgroundGrace()
        applyBackgroundNotice(backgroundNotice.becameBackground())
    }

    /// Control Center, Face ID and the app switcher pass through here and come straight back, so the Mac is told only if it lasts.
    func becameInactive() {
        beginBackgroundGrace()
        applyBackgroundNotice(backgroundNotice.becameInactive(now: .now))
    }

    func applyBackgroundNotice(_ action: BackgroundNoticeDebounce.Action) {
        switch action {
        case .none:
            break
        case .tell(let background):
            backgroundNoticeTask?.cancel()
            backgroundNoticeTask = nil
            tellMacsAppIsBackground(background)
        case .wait(let deadline):
            guard backgroundNoticeTask == nil else { return }
            backgroundNoticeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self else { return }
                backgroundNoticeTask = nil
                applyBackgroundNotice(backgroundNotice.fire(now: .now))
            }
        }
    }

    /// Picture in Picture keeps the app alive and drawing, so the Mac must keep sending while it is up.
    func pictureInPictureChanged(active: Bool) {
        tellMacsAppIsBackground(!active && UIApplication.shared.applicationState != .active)
    }

    func tellMacsAppIsBackground(_ background: Bool) {
        for session in sessions { session.wire?.sendClientState(background: background) }
    }

    // Held while any Mac is open or retrying: iOS suspends the process, and a LAN session that drops to `.failed` before `enteringBackground()` would freeze `Task.sleep` and never show the "dropped" card.
    func beginBackgroundGrace() {
        guard hasOpenSession, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: String(localized: "Peering session")) { [weak self] in
            Task { @MainActor in self?.backgroundTimeExpired() }
        }
    }

    func enteringForeground() {
        applyBackgroundNotice(backgroundNotice.becameActive())
        // If the card still shows dropped and the Mac is back in reach, jump to "reconnecting" instead of leaving "dropped" up for the round trip. `reachability(ofHost:)` keeps it in agreement with the picker's dot.
        if let session = activeSession,
           !session.phase.holdsSession,
           !session.userEndedDeliberately,
           let hostID = session.hostID,
           reachability(ofHost: hostID).isReachable {
            SessionActivity.shared.showReconnecting(
                hostName: session.hostName ?? String(localized: "the Mac"),
                startedAt: session.sessionStartedAt,
                path: MacSession.activityPath(session.connectionPath)
            )
        } else {
            SessionActivity.shared.returningToForeground()
        }
        endBackgroundAssertion()
        verifyLiveSessions()
        notifier.registerIfAuthorised()
        reportUnreadablePins()

        // Re-read before anything is armed: a subscription that ran out while off screen produced no transaction, so the held plan can be hours stale.
        Task { await storeManager.rereadEntitlement() }
        // A browse that died in the background sits behind its own backoff, so restart it now.
        if browseFailed { restartBrowsing() }

        // A moment for the local network before the ladder leaves for the relay: the browser is suspended with the app, so an instant resume finds no Macs, dials the relay, and is handed to the LAN a beat later, costing the picture twice. Paid only when a session names a Mac the list lacks.
        // A remembered address is dialled at once, racing the relay, so it needs no wait.
        let waitingForALocalMac = sessions.contains { session in
            guard let hostID = session.hostID else { return false }
            return !hosts.contains { $0.id == hostID } && rememberedLANHost(hostID) == nil
        }
        guard waitingForALocalMac else {
            resumeEveryMac()
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.localMacGrace))
            guard let self else { return }
            self.resumeEveryMac()
        }
    }

    static let localMacGrace = 900

    func resumeEveryMac() {
        // The ladder's pending wait is cut short first: a Mac mid-rung would otherwise wait for time that has already passed.
        for session in sessions { session.resumeWithoutWaiting() }
        resumeIfNeeded()
        // The layer's contents do not survive the background and the host sends nothing for an unchanged Mac, so this brings the picture back.
        activeSession?.renderer.repaintAfterForegrounding()
    }

    /// Takes down the card and tells the Mac, instead of a Lock Screen card claiming a connection that ended; the user gets a banner.
    func backgroundTimeExpired() {
        let shouldEndSession = BackgroundSessionExpiry.shouldEndSession(
            assertionIsActive: backgroundTask != .invalid,
            appIsBackground: UIApplication.shared.applicationState == .background,
            hasOpenSession: hasOpenSession,
            // PiP is a system-owned background presentation: while active iOS keeps the app alive, so the expiring assertion must not tear down the session under the floating window.
            pictureInPictureIsActive: SessionPiP.shared.isActive
        )
        endBackgroundAssertion()
        // Every Mac in one call, since `disconnect(deliberate:)` means all: one behind the active would be killed unobserved.
        guard shouldEndSession else { return }
        disconnect(deliberate: false)
    }

    func endBackgroundAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
