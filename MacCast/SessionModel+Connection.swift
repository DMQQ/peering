import RemoteCore
import SwiftUI

/// Pairing, connecting, and getting back to a Mac.
///
/// An extension on the model rather than a type of its own: this state is the
/// model's, and splitting the *type* would mean either exposing it or copying it.
extension SessionModel {
    /// What this device can say about what it bought, in the shape the relay asks for it.
    ///
    /// Built in one place because every route to a relay session has to carry it, and a call
    /// site that forgets part of it is a paying subscriber counted down at the free allowance
    /// — the failure this whole arrangement exists to remove. The receipt is the part that
    /// matters: the relay verifies it against Apple's root and meters by the product it names,
    /// and the plan beside it is read only when there is no receipt to check, which is the case
    /// for an app older than this one and for the moment before ``StoreManager/start()`` has
    /// asked the App Store what is current. See ``RelayEntitlement``.
    var relayEntitlement: RelayEntitlement {
        RelayEntitlement(
            plan: storeManager.relayPlan.rawValue,
            jwsRepresentation: storeManager.activeJWS,
            apiKey: storeManager.apiKey
        )
    }

    /// The relay target for a paired Mac.
    func relayTarget(hostID: String, name: String) -> ClientSession.Target {
        .relay(hostID: hostID, name: name, entitlement: relayEntitlement)
    }

    /// The relay target for a Mac this device has never met.
    func relayPairingTarget(hostID: String, name: String) -> ClientSession.Target {
        .relayPairing(hostID: hostID, name: name, entitlement: relayEntitlement)
    }

    /// Starts a first pairing with a Mac that is not on this network.
    ///
    /// **This is the one path into a Mac with no pin behind it, and the licence is the user.**
    /// Every other route in — the trusted rows, the last-Mac reconnect, the resume after a drop
    /// — insists on a stored pin for the ID before it will dial the relay, because each of them
    /// is the app acting on its own about a Mac it already knows. Here the user has just read a
    /// device ID off the other machine and typed or scanned it, which is a decision the app
    /// cannot make for them and must not make on their behalf. So the guard is not relaxed; it
    /// is answered. The Mac still asks both people to compare six digits before it trusts this
    /// device, and that comparison is what authorises the pairing — the ID only decided who was
    /// asked. See ``ClientSession/Target/relayPairing(hostID:name:entitlement:)``.
    ///
    /// - Returns: what is wrong with the text, or `nil` once an attempt is in flight. The caller
    ///   shows the sentence where the user can see the field it came from.
    @discardableResult
    func pairWithRemoteMac(hostID text: String) -> PairingPayloadError? {
        let hostID: String
        do {
            hostID = try PairingPayload.hostID(from: text)
        } catch let problem as PairingPayloadError {
            return problem
        } catch {
            // `PairingPayload` reports every refusal as one of its own cases, so this is
            // unreachable rather than a fallback — but the field is the user's text and
            // something has to be said about it either way.
            return .notAnIdentifier(text)
        }

        guard allowsRelay else {
            // Not a failure of the pairing, and not an error card: a setting the user turned
            // off, on a screen that says so. Said here as well because this is the path that
            // cannot work at all without it — the Mac is not on this network, so there is no
            // second route to try.
            append(note: "Remote access is turned off in Settings, so a Mac on another network cannot be reached.")
            return nil
        }

        // Named "A Mac" until the handshake says otherwise. A first pairing has never been
        // told what the Mac calls itself, and the ID is not a name — inventing one from it
        // would put six hexadecimal characters where a person expects a Mac's name.
        connect(to: relayPairingTarget(hostID: hostID, name: "A Mac"))
        return nil
    }

    func confirmPairing(accepted: Bool) {
        // Declining ends the session from the Mac's side too, and that arrives as a
        // `.disconnected` like any other — with the model's phase still on `.confirming`.
        // Without this the user's own "no" comes back to them as a lost connection.
        if !accepted { userEndedSession = true }
        session?.confirmPairing(accepted: accepted)
    }

    /// Ends the session now.
    ///
    /// `deliberate` answers "did the user mean to do this", which is not the same question as
    /// "who called this function". A disconnect the user tapped is silent; one iOS forced
    /// because it is about to suspend the app is not, because they are looking at something else
    /// and a banner is the only way they will ever hear about it.
    /// Ends the session now.
    ///
    /// `deliberate` answers "did the user mean to do this", which is not the same question as
    /// "who called this function". A disconnect the user tapped is silent; one iOS forced
    /// because it is about to suspend the app is not, because they are looking at something else
    /// and a banner is the only way they will ever hear about it.
    func disconnect(deliberate: Bool = true) {
        // Taken before anything else is, because everything below is about taking this session
        // apart — and the card that outlives a non-deliberate end needs both to say what was
        // lost. After the lines beneath them they are simply nil.
        let wasStartedAt = sessionStartedAt
        let wasPath = Self.activityPath(connectionPath)
        finishSessionHistory()

        // Recorded before anything moves. `ClientSession` announces the end itself, and by
        // the time that event is applied the phase below has already been set — so this flag
        // is the only evidence left that the user, and not the network, ended it.
        userEndedSession = deliberate
        // Only a deliberate one. A drop, and the end iOS forces on a backgrounded app, are the
        // two cases where coming back to the app should find the session restored.
        if deliberate {
            UserDefaults.standard.set(false, forKey: Self.resumeKey)
            stopReconnecting()
        }
        sessionStartedAt = nil
        session?.disconnect()
        session = nil
        videoPoll?.cancel()
        videoPoll = nil
        renderer.reset()
        connectionPath = nil
        latchedModifiers = []
        phase = .disconnected

        // Below the assignment rather than above it: this is the path that *is* the phase
        // change, and the announcement that follows it sees no difference to act on.
        //
        // Which of the two, though, turns on `deliberate` — and this method is how *both*
        // arrive, because the end iOS forces when the background grace runs out comes through
        // here too. `sessionEnded()` used to be called unconditionally, so backgrounding the
        // app made the card vanish as though the user had quit: the one moment the card is
        // most useful, and it was being taken away. That is the opposite of what `deliberate`
        // is documented to mean two paragraphs up.
        // The keepalive and the floating window go with the session, and this method has to do
        // it itself for the same reason the card does: it sets the phase rather than letting
        // the event path announce it, so nothing that hangs off a phase *change* runs. Without
        // this, quitting left silence playing and a floating window of a Mac nobody is
        // connected to.
        SessionAudio.shared.end()
        SessionPiP.shared.stop()

        if deliberate {
            SessionActivity.shared.sessionEnded()
        } else {
            SessionActivity.shared.sessionDropped(
                hostName: hostName ?? "the Mac",
                startedAt: wasStartedAt,
                path: wasPath
            )
        }
    }

    /// A trusted Mac the user asked for, waiting on discovery to produce it.
    ///
    /// Kept for an in-flight Bonjour update from an older request. New requests no longer need
    /// to wait: they use the relay immediately when the Mac is not visible on the LAN.
    /// Connects to a Mac this device has paired with before, by ID.
    ///
    /// Bonjour wins when it has the Mac, preserving the existing direct LAN path. Otherwise the
    /// same stable host ID is sent to the relay; no remembered IP address is involved.
    func connectToTrusted(hostID: String) {
        if let host = hosts.first(where: { $0.id == hostID }) {
            pendingHostID = nil
            connect(to: .discovered(host))
            return
        }
        guard allowsRelay else {
            // Waited for rather than refused, and the waiting is not a spinner over nothing:
            // the Mac is paired, and the only thing missing is that it is not on this network
            // yet. That is a state that ends by itself — walking back into range, or the Mac
            // waking — and the browser's next update connects with no further tap. The row
            // already draws the progress indicator for it.
            pendingHostID = hostID
            return
        }
        pendingHostID = nil
        connect(to: relayTarget(hostID: hostID, name: displayName(forHostID: hostID) ?? "A Mac"))
    }

    /// Explicit route choices from the trusted-Mac row. The regular row tap stays automatic;
    /// these two methods deliberately do not fall back to the other transport.
    /// Explicit route choices from the trusted-Mac row. The regular row tap stays automatic;
    /// these two methods deliberately do not fall back to the other transport.
    func connectToTrustedOverLAN(hostID: String) {
        guard let host = hosts.first(where: { $0.id == hostID }) else { return }
        pendingHostID = nil
        connect(to: .discovered(host))
    }

    func connectToTrustedOverRelay(hostID: String) {
        guard allowsRelay, pins.hostIDs.contains(hostID) else { return }
        pendingHostID = nil
        connect(to: relayTarget(hostID: hostID, name: displayName(forHostID: hostID) ?? "A Mac"))
    }

    // MARK: - Quick connect

    /// Where the name of the last Mac this device connected to is kept.
    ///
    /// In `UserDefaults` rather than in the app group the widget would need to read it, because
    /// the widget does not need to know *which* Mac — it offers to connect, and the app decides
    /// to what. That keeps a shared container, its entitlement and its provisioning out of a
    /// feature whose whole job is to save one tap.
    func connectToManualAddress() {
        guard let port = UInt16(manualPort.trimmingCharacters(in: .whitespaces)) else {
            append(note: "“\(manualPort)” is not a port number.")
            return
        }
        let host = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        connect(to: .address(host: host, port: port))
    }

    /// Reconnects to the Mac this device used last. A matching Bonjour result uses the direct
    /// LAN path; a trusted ID that is not currently visible uses the relay.
    func reconnectToLastHost() {
        guard !phase.holdsSession else { return }
        let defaults = UserDefaults.standard
        let hostID = defaults.string(forKey: Self.lastHostIDKey)
        let name = defaults.string(forKey: Self.lastHostNameKey)
        if let host = hosts.first(where: { hostID != nil ? $0.id == hostID : $0.name == name }) {
            connect(to: .discovered(host))
        } else if let hostID, allowsRelay, pins.hostIDs.contains(hostID) {
            connect(to: relayTarget(hostID: hostID, name: name ?? displayName(forHostID: hostID) ?? "A Mac"))
        }
    }

    /// Whether the next sight of the last Mac should put the session back.
    ///
    /// Written down rather than remembered, because the case that matters most is the one where
    /// iOS killed the app while it was backgrounded: nothing of the session survives that, and
    /// "there was one" has to have been recorded before it happened.
    /// Puts the session back, if there was one and the user did not end it.
    ///
    /// Called from three places because they cover different arrivals. Coming back to the front
    /// is the short trip — the app is still in memory and the Mac is already in the browser's
    /// list. A host appearing is the cold launch, where the browser has only just started and
    /// the Mac is not in a list that has not been filled in yet. And a timer is the drop that
    /// happens while the user is looking at the screen, which is the case they notice.
    ///
    /// A deliberate disconnect clears the flag and nothing here fires; a dropped connection
    /// leaves it set, which is exactly the case this exists for.
    func resumeIfNeeded() {
        // `session` is assigned synchronously in ``connect(to:)``, before the phase has heard
        // anything, while the browser fires `updated` on its own schedule — so the session is
        // the only reliable evidence that an attempt is already in flight. Without it the retry
        // and the browser can both start one, and each silently closes the other's connection.
        guard session == nil, !phase.holdsSession else {
            stopReconnecting()
            return
        }
        guard UserDefaults.standard.bool(forKey: Self.resumeKey) else { return }

        let defaults = UserDefaults.standard
        let hostID = defaults.string(forKey: Self.lastHostIDKey)
        let name = defaults.string(forKey: Self.lastHostNameKey)
        if let host = hosts.first(where: { hostID != nil ? $0.id == hostID : $0.name == name }) {
            stopReconnecting()
            isResuming = true
            connect(to: .discovered(host))
        } else if let hostID, allowsRelay, pins.hostIDs.contains(hostID) {
            stopReconnecting()
            isResuming = true
            connect(to: relayTarget(hostID: hostID, name: name ?? displayName(forHostID: hostID) ?? "A Mac"))
        } else {
            // Includes the LAN-only case: the Mac is paired and simply not here yet. The ladder
            // keeps asking until it appears, which is the whole of what "wait for it to come
            // back" means — stopping at the first attempt that found nothing would end a resume
            // that has not failed, only not succeeded yet.
            scheduleReconnect()
        }
    }

    /// Arms the next attempt, if there is one left to make.
    /// Arms the next attempt, if there is one left to make.
    func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        guard reconnectAttempt < Self.reconnectDelays.count else {
            isReconnecting = false
            // The reconnect ladder gave up. `sessionMoved` is not called again because there is
            // no phase change — the phase is already `.failed` or `.disconnected` — so the Live
            // Activity has to be told directly, or it stays on "Reconnecting…" indefinitely.
            SessionActivity.shared.sessionDropped(
                hostName: hostName ?? "the Mac",
                startedAt: nil,
                path: Self.activityPath(connectionPath)
            )
            return
        }
        let delay = Self.reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1
        isReconnecting = true
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.resumeIfNeeded()
        }
    }

    /// Stops the retry, *without* resetting the backoff.
    ///
    /// The counter belongs to a run of attempts, and resetting it here is what turned a failing
    /// reconnect into a permanent loop: every cycle called this, so the attempt count returned to
    /// zero and the delays never advanced past the first second. Only a session that actually
    /// came up clears it — see the `.ready` branch in ``apply(_:)``.
    /// Stops the retry, *without* resetting the backoff.
    ///
    /// The counter belongs to a run of attempts, and resetting it here is what turned a failing
    /// reconnect into a permanent loop: every cycle called this, so the attempt count returned to
    /// zero and the delays never advanced past the first second. Only a session that actually
    /// came up clears it — see the `.ready` branch in ``apply(_:)``.
    func stopReconnecting() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
    }

    // MARK: - Backgrounding

    /// The reprieve iOS grants a backgrounded app, and what happens when it runs out.
    ///
    /// There is no background mode a remote desktop can honestly claim — the app is not playing
    /// audio, tracking a location or servicing a call — so this is the whole of it. It is not a
    /// fix for the session ending when the app is backgrounded, and cannot be: it buys the few
    /// seconds that make switching to another app for something and coming straight back
    /// survivable, and nothing beyond that.
    /// Called when the app is backgrounded with a session up.
    func enteringBackground() {
        SessionActivity.shared.enteringBackground()

        // Started here rather than left to `canStartPictureInPictureAutomaticallyFromInline`.
        // That flag is set, and the picture does float when it is started by hand — but iOS
        // never takes the hint. Automatic PiP is gated on the system considering the app to be
        // *playing*, and an `AVAudioPlayer` running silence is not something it counts, however
        // active the session is.
        //
        // Asking at the one moment it is wanted costs nothing and does not depend on that
        // judgement — and the moment matters: this runs as the app leaves the screen, which is
        // when `startPictureInPicture` still has a view hierarchy to lift the layer out of.
        SessionPiP.shared.backgrounding(sessionIsUp: phase.holdsSession)

        // Also keep the process alive when the reconnect ladder is running. A LAN session that
        // drops moves to `.failed` immediately — before `enteringBackground()` — so
        // `phase.holdsSession` is already false. Without this, the app suspends, `Task.sleep`
        // freezes, and the "dropped" Live Activity card is never shown.
        guard (phase.holdsSession || isReconnecting), backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Peering session") { [weak self] in
            Task { @MainActor in self?.backgroundTimeExpired() }
        }
    }

    func enteringForeground() {
        SessionActivity.shared.returningToForeground()
        endBackgroundAssertion()
        // A browse that died while the app was in the background has been sitting behind its own
        // backoff in a suspended process. Starting one now is the difference between a list that
        // is there when the user looks and one that fills in several seconds later.
        if browseFailed { restartBrowsing() }
        resumeIfNeeded()
    }

    /// Ends the session when the background window runs out, rather than letting the system
    /// kill it.
    ///
    /// The difference is visible in two places. The Live Activity is taken down and the Mac is
    /// told the session is over, instead of a Lock Screen card sitting there claiming a
    /// connection that ended — which it cannot correct, because nothing of ours is running to
    /// correct it with. And the user, who is not looking, gets a banner.
    /// Ends the session when the background window runs out, rather than letting the system
    /// kill it.
    ///
    /// The difference is visible in two places. The Live Activity is taken down and the Mac is
    /// told the session is over, instead of a Lock Screen card sitting there claiming a
    /// connection that ended — which it cannot correct, because nothing of ours is running to
    /// correct it with. And the user, who is not looking, gets a banner.
    func backgroundTimeExpired() {
        endBackgroundAssertion()
        if phase.holdsSession {
            disconnect(deliberate: false)
        } else if isReconnecting {
            // Background time ran out before the reconnect ladder finished. Cancel it and show
            // the "dropped" card; the ladder will restart when the user returns to the foreground.
            stopReconnecting()
            SessionActivity.shared.sessionDropped(
                hostName: hostName ?? "the Mac",
                startedAt: nil,
                path: Self.activityPath(connectionPath)
            )
        }
    }

    func endBackgroundAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Forgets the pin for a Mac. The Mac keeps its half, so the next connection is refused
    /// by it until it is unpaired on that side too — which is the honest behaviour for
    /// "forget", as opposed to a silent re-pair.
    /// Forgets the pin for a Mac. The Mac keeps its half, so the next connection is refused
    /// by it until it is unpaired on that side too — which is the honest behaviour for
    /// "forget", as opposed to a silent re-pair.
    func forget(hostID: String) {
        pins.remove(hostID: hostID)
        pairedHostIDs = pins.hostIDs
        publishKnownMacs()
        append(note: "Forgot \(hostID). Unpair this device on the Mac as well.")
    }

    // A `resetDeviceIdentity()` used to sit here: it destroyed the key, cleared the pins and let
    // `DeviceIdentity` mint a new client ID. It went with the buttons that called it. The relay
    // counts relay time per client ID, so the method's whole effect, from the relay's side, was to
    // hand the caller a fresh allowance — every reset was another day's worth, whatever the plan
    // said. Reinstating it means reinstating that, so it should come back only alongside a quota
    // the relay counts against something a reset cannot change.

    func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        device.saveName(trimmed)
        device = DeviceIdentity.loadOrCreate(defaultName: trimmed)
    }

}
