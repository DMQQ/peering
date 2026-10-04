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
            // Recorded before anything is shown, so the name outlives the connection that carried
            // it. Assigned rather than only inserted, because a client may rename itself.
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
            record("\(clientName) connected · \(detail)")
            // A client that has just arrived has no source list, so it is sent one now rather than
            // waiting for an application to launch. It is also the first read of the catalogue,
            // which is what needs Screen Recording permission: a refusal here is logged and ignored,
            // and the video path reports it properly if the client then asks for a source.
            //
            // Immediate, because this client is not a change to the list: it is waiting to ask for
            // the source it was last on, and the interval between pushes would hold that up for as
            // long as three seconds while this Mac captures a display nobody asked for.
            coordinator?.refreshCatalog(immediate: true)
            acquireSleepAssertion()
            wakeDisplayIfAsleep()
            // Somebody is using this Mac: the schedule's window is open whatever the clock says,
            // and a release the user asked for on the last disconnect is spent. See
            // ``keepAwakeIsInForce``.
            Task { await rearmKeepAwake() }

        case .clientDisconnected(let clientID, let clientName):
            connectedClients.removeAll { $0.id == clientID }
            endSession(id: clientID)
            // The last one out stops the watch. Anybody still attached keeps being told.
            if connectedClients.isEmpty {
                stopScreenWatch()
                textFocusWatcher.stop()
                coordinator?.watchSourceThumbnails(false)
            }
            record("\(clientName) disconnected")
            // The moment nothing is left that can release what this client was holding: a client
            // that dies mid-chord or mid-drag takes its key-up with it, and the Mac would sit
            // holding ⌘ or a mouse button until a real one arrived from the keyboard. Only on the
            // last client, because the held state is the Mac's, so releasing it while another
            // client is connected would drop a modifier that client is holding for real.
            if connectedClients.isEmpty {
                input.releaseAll()
                releaseSleepAssertion()
                setPrivacyMode(false)
                // **The moment this feature exists for.** The last client has gone, and whatever
                // the keep-awake switches are holding is now being held for nobody. The schedule
                // gets its say first: outside its window this is where the Mac is let go, and the
                // prompt would be asking about something already done.
                Task { @MainActor in
                    await applyKeepAwakeSchedule()
                    // Asked only if something is *still* being held. Outside the schedule's window
                    // the line above has just let the Mac go, and a prompt offering to do what has
                    // already been done is a prompt nobody can answer sensibly.
                    if keepAwakeIsInForce, preventLidCloseSleep || keepRunningWithLidClosed {
                        scheduleKeepAwakePrompt()
                    }
                }
                // **And the displays this phone asked for go with it.** A display made at a
                // client's request is that client's, and it is temporary by construction: left
                // behind it is a screen the Mac's own user did not make, cannot take away from the
                // app that made it, and finds again every time they look at the display list. This
                // is the same sentence as the three lines above — nothing is left that can release
                // what the client was holding, so this releases it — and it is here rather than on
                // a command from the phone because a phone that quits, is killed or crashes sends
                // nothing at all. The cost is a client that drops and reconnects losing its extra
                // displays with the connection; they are three taps to make again, and the
                // arrangement they were carrying is a thing the phone remembers how to ask for.
                removeAllManagedVirtualDisplays()
            }

        case .pairingCode(let code, let clientName, let isRemote):
            pairing = PairingPrompt(clientName: clientName, code: code, isRemote: isRemote)
            record(isRemote
                   ? "Pairing request from \(clientName), over the relay"
                   : "Pairing request from \(clientName)")
            // The code is not logged: the unified log is readable by any local process, and the
            // digits are already on screen for the user to compare.
            hostLog.notice("pairing code displayed for \(clientName, privacy: .public)")

        case .pairingCompleted(let clientName, let accepted):
            pairing = nil
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

    /// What to tell the user about how a desktop switch reached its Space.
    ///
    /// **Two of these were silent, and silence is what made them expensive to find.** The route
    /// the host falls back to moves the Space without running the Dock's window show/hide cycle, so
    /// the display can go on compositing the desktop that was there before, with the arriving one's
    /// windows drawn over it. On the phone that reads as a tile that shows two desktops, or as a
    /// picture that has frozen, and it clears the moment anything on the Mac moves because the
    /// encoder then has a frame to send. Nothing said why, so the report on the Mac said the switch
    /// was accepted, which it was.
    ///
    /// The shortcut one is the case this was written for: `AXIsProcessTrusted()` and the symbol
    /// both say the chord route is available, so the host believes it is, and the only thing that
    /// knows otherwise is a chord that does not move anything. Measured on this Mac on 2026-09-25:
    /// entries 79 and 80 of `com.apple.symbolichotkeys`, "Move left a space" and "Move right a
    /// space", were enabled with no key bound, and every switch took the fallback.
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

    /// Darkens every display this Mac can be dark, and covers the rest.
    ///
    /// Two mechanisms, because neither reaches every display. A brightness write is the good one
    /// where it holds: nothing is drawn over the picture, so the phone's stream is untouched by
    /// construction, and the Mac's own brightness-up key still brings the panel back. A display
    /// that will not take the write is covered instead by a window that the window server keeps
    /// out of any capture, which reaches the picture the same way and survives a monitor whose
    /// own firmware refuses what macOS hands it.
    func setPrivacyMode(_ enabled: Bool) {
        if enabled {
            guard !privacyModeEnabled else { return }
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
            privacyModeEnabled = false
            observeDisplayChanges(false)
            displayPrivacy.restore()
            privacyCurtain.lift()
            record("Privacy Mode off; displays restored")
        }
    }

    /// Dims every display that takes a brightness write, covers the ones that do not, and says
    /// what it managed.
    ///
    /// Called again for a display attached during a session, which is why it works from the
    /// display list rather than from anything remembered: a display nobody has hidden is exactly
    /// what this feature promises not to have.
    func applyPrivacyCover() {
        let dimmed = (try? displayPrivacy.enable()) ?? []
        let covered = privacyCurtain.cover(
            DisplayPrivacyController.activeDisplayIDs().filter {
                // A display this host made itself has no panel in front of anyone, so there is
                // nothing in front of it to cover.
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

    /// Says, and tells the phone, about a display Privacy Mode left visible.
    ///
    /// Reached twice for one enable: once for a display no cover could be put on at all, and once
    /// from ``DisplayPrivacyCurtain`` for a cover that had to come back down, which the window
    /// server only answers after the call that put it up has returned.
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

    /// Watches the display list for as long as there is a cover to keep up to date.
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
