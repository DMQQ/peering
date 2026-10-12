import AppKit
import ApplicationServices
import Foundation
import IOKit.pwr_mgt
import Observation
import RemoteCore
import WidgetKit
import os

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

extension HostModel {
    // MARK: - Event handling

    func apply(_ event: HostEvent) {
        switch event {
        case .listening(let port):
            status = .listening(port: port)
            record("Listening on port \(port) as “\(deviceName)”")

        case .stopped:
            status = .idle
            record("Stopped listening")

        case .clientConnected(let clientID, let clientName, let viaRelay, let detail):
            if !isConnected(clientID) {
                connectedClients.append(
                    ConnectedClient(id: clientID, name: clientName, since: Date(), viaRelay: viaRelay)
                )
            }
            // Recorded first so the name outlives the connection; assigned because a client may rename itself.
            if clientNames[clientID] != clientName {
                clientNames[clientID] = clientName
                UserDefaults.standard.set(clientNames, forKey: Self.clientNamesKey)
            }
            // Before the source the phone names in its hello is looked up: a window moved or
            // resized while nobody was connected would otherwise be captured where it used to be.
            coordinator?.forgetWindowListIfStale()
            beginSession(id: clientID, name: clientName)
            startScreenWatch()
            let input = self.input
            textFocusWatcher.start(
                transform: { input.transform },
                onChange: { [weak server] focus in server?.broadcastTextFocus(focus) },
                onField: { [weak server] state in server?.broadcastFieldState(state) }
            )
            pointerWatcher.start(
                transform: { input.transform },
                lastInjected: { input.clickLocation },
                onMove: { [weak server] point in server?.broadcastPointer(point) }
            )
            record("\(clientName) connected · \(detail)")
            // Sent a source list now and immediately: the client is waiting to ask for its last source and the push interval would hold it up. This is also the first catalogue read, which needs Screen Recording; a refusal here is ignored and the video path reports it.
            coordinator?.refreshCatalog(immediate: true)
            acquireSleepAssertion()
            wakeDisplayIfAsleep()
            // Somebody is using this Mac: the schedule window is open and a release asked for on the last disconnect is spent. See keepAwakeIsInForce.
            Task { await rearmKeepAwake() }

        case .clientDisconnected(let clientID, let clientName):
            connectedClients.removeAll { $0.id == clientID }
            endSession(id: clientID)
            // The last one out stops the watch. Anybody still attached keeps being told.
            if connectedClients.isEmpty {
                stopScreenWatch()
                textFocusWatcher.stop()
                pointerWatcher.stop()
                coordinator?.watchSourceThumbnails(false)
            }
            record("\(clientName) disconnected")
            // Only on the last client: one that dies mid-chord takes its key-up with it, but another client may be holding a modifier for real.
            if connectedClients.isEmpty {
                input.releaseAll()
                releaseSleepAssertion()
                setPrivacyMode(false, counted: false)
                lastCountedCaptureSource = nil
                // The last client has gone: the schedule gets its say first, then the keep-awake prompt.
                Task { @MainActor in
                    await applyKeepAwakeSchedule()
                    // Only if something is still held; outside the schedule window the Mac has just been let go.
                    if keepAwakeIsInForce, preventLidCloseSleep || keepRunningWithLidClosed {
                        scheduleKeepAwakePrompt()
                    }
                }
                // Displays a client asked for are its own and temporary; a phone that quits or crashes sends no command, so they go with the last client.
                removeAllManagedVirtualDisplays()
            }

        case .pairingCode(let sessionID, let code, let secret, let clientName, let isRemote):
            pairing = PairingPrompt(sessionID: sessionID, clientName: clientName, code: code, secret: secret, isRemote: isRemote)
            record(isRemote
                   ? "Pairing request from \(clientName), over the relay"
                   : "Pairing request from \(clientName)")
            // The code is not logged: the unified log is readable by any local process, and the
            // digits are already on screen for the user to compare.
            hostLog.notice("pairing code displayed for \(clientName, privacy: .public)")

        case .pairingNeedsApproval(let sessionID, _):
            if pairing?.sessionID == sessionID { pairing?.needsApproval = true }

        case .pairingAbandoned(let sessionID):
            // A phone that quits or is relaunched mid-pairing leaves a question nobody is asking: its buttons would answer a session that no longer exists.
            if pairing?.sessionID == sessionID { pairing = nil }

        case .pairingCompleted(let sessionID, let clientName, let accepted):
            if pairing?.sessionID == sessionID { pairing = nil }
            lastOutcome = PairingOutcome(clientName: clientName, accepted: accepted)
            pairedClientIDs = pins?.peerIDs ?? []
            record(accepted ? "Paired with \(clientName)" : "Pairing with \(clientName) rejected")

        case .failed(let message):
            record(message)
            // A failure while listening is worth surfacing as status; a per-connection one is not,
            // or one bad client would blank out a healthy listener.
            if !status.isListening {
                status = .failed(message)
            }
        }
    }

    /// The fallback route moves the Space without the Dock show/hide cycle, so the display can keep compositing the old desktop (a tile showing two desktops, or a frozen picture) until something moves.
    /// AXIsProcessTrusted and the symbol both say the chord route is available; only a chord that moves nothing reveals unbound Move left/right a space shortcuts (symbolichotkeys entries 79 and 80).
    func report(spaceSwitchRoute route: SpaceSwitchRoute, index: Int, display: UInt32) {
        switch route {
        case .chord:
            record("Desktop \(index) on display \(display) accepted")
        case .direct(.chordDidNotLand):
            record(
                """
                Desktop \(index) switched, but the picture may still show the one before it. This \
                Mac's "Move left a space" and "Move right a space" shortcuts have no keys set, so \
                the switch has no transition to follow. Turn them on in System Settings > Keyboard \
                > Keyboard Shortcuts > Mission Control.
                """,
                level: .warning
            )
        case .direct(.pointerElsewhere):
            record(
                "Desktop \(index) switched. Move the pointer onto this display first for the picture to follow it.",
                level: .warning
            )
        case .direct(.noPermission):
            record(
                "Desktop \(index) switched. Grant Peering the Accessibility permission for the picture to follow it.",
                level: .warning
            )
        case .direct(.noApproach):
            record("Desktop \(index) on display \(display) accepted")
        case .refused:
            record(
                "Desktop \(index) on display \(display) refused by the window server",
                level: .warning
            )
        }
    }

    func record(_ message: String, level: HostLogEntry.Level = .info) {
        // `.public` because these lines are the diagnostics, and the one sensitive value, the
        // pairing code, is deliberately never in them.
        hostLog.notice("\(message, privacy: .public)")
        log.append(HostLogEntry(level: level, message: message))
        if log.count > Self.maxEvents {
            log.removeFirst(log.count - Self.maxEvents)
        }
    }

    /// A brightness write where it holds, otherwise a cover window the window server keeps out of capture.
    /// `counted` is false where the host turns it off itself, because a session ended: that is not a choice.
    func setPrivacyMode(_ enabled: Bool, counted: Bool = true) {
        if enabled {
            guard !privacyModeEnabled else { return }
            Analytics.track(.privacyModeChanged)
            // Before the cover goes up, so a display that arrives while it is up is not missed:
            // nothing else tells the host that the Mac's display list changed.
            observeDisplayChanges(true)
            privacyModeEnabled = true
            applyPrivacyCover()
        } else {
            guard privacyModeEnabled else {
                // Also repairs a persisted level after an interrupted run.
                displayPrivacy.restore()
                return
            }
            if counted { Analytics.track(.privacyModeChanged) }
            privacyModeEnabled = false
            observeDisplayChanges(false)
            displayPrivacy.restore()
            privacyCurtain.lift()
            record("Privacy Mode off; displays restored")
        }
    }

    /// Works from the display list, not remembered state, since a display attached mid-session must not escape.
    func applyPrivacyCover() {
        let dimmed = (try? displayPrivacy.enable()) ?? []
        let covered = privacyCurtain.cover(
            DisplayPrivacyController.activeDisplayIDs().filter {
                !dimmed.contains($0) && VirtualDisplay.name(for: $0) == nil
            }
        )

        let total = dimmed.count + covered.covered.count
        guard total > 0 else {
            let reason = covered.refused.first?.reason ?? "no display here takes a brightness change"
            record("Could not enable Privacy Mode: \(reason)", level: .failure)
            server?.broadcastNotice(NoticePayload(
                message: "Privacy Mode could not darken this Mac's displays.",
                symbol: "display.trianglebadge.exclamationmark"
            ))
            return
        }
        // Said as what happened rather than as a success: a Mac with one third-party monitor dims
        // nothing at all and is still private, and a Mac where the cover failed is not.
        record("""
            Privacy Mode on \(total) display\(total == 1 ? "" : "s") \
            (\(dimmed.count) dimmed, \(covered.covered.count) covered)
            """)
        reportUncovered(covered.refused)
    }

    /// Reached twice per enable: for a display no cover could be put on, and from DisplayPrivacyCurtain for a cover taken back down.
    func reportUncovered(_ refusals: [DisplayPrivacyCurtain.Refusal]) {
        guard !refusals.isEmpty else { return }
        for refusal in refusals {
            record("Privacy Mode could not cover \(refusal.display): \(refusal.reason)", level: .failure)
        }
        server?.broadcastNotice(NoticePayload(
            message: refusals.count == 1
                ? "One of this Mac's displays is still visible: Privacy Mode could not cover it."
                : "\(refusals.count) of this Mac's displays are still visible: Privacy Mode could not cover them.",
            symbol: "display.trianglebadge.exclamationmark"
        ))
    }

    func observeDisplayChanges(_ observing: Bool) {
        guard observing != (displayObserver == nil) else { return }
        if observing {
            displayObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Hopped rather than assumed: keeping the covers up to date is main-actor work,
                // and the queue this notification arrives on is not a promise this file can check.
                Task { @MainActor [weak self] in
                    guard let self, self.privacyModeEnabled else { return }
                    self.applyPrivacyCover()
                }
            }
        } else if let observer = displayObserver {
            NotificationCenter.default.removeObserver(observer)
            displayObserver = nil
        }
    }
}
