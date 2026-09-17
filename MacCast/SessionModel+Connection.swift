import RemoteCore
import SwiftUI

/// Pairing, connecting, and getting back to a Mac.
///
/// An extension on the model rather than a type of its own: this state is the
/// model's, and splitting the *type* would mean either exposing it or copying it.
extension SessionModel {
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
        connect(to: .relay(hostID: hostID, name: displayName(forHostID: hostID) ?? "A Mac", apiKey: storeManager.apiKey))
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
        connect(to: .relay(hostID: hostID, name: displayName(forHostID: hostID) ?? "A Mac", apiKey: storeManager.apiKey))
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
            connect(to: .relay(hostID: hostID, name: name ?? displayName(forHostID: hostID) ?? "A Mac", apiKey: storeManager.apiKey))
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
            connect(to: .relay(hostID: hostID, name: name ?? displayName(forHostID: hostID) ?? "A Mac", apiKey: storeManager.apiKey))
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

        guard phase.holdsSession, backgroundTask == .invalid else { return }
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
        guard phase.holdsSession else { return }
        disconnect(deliberate: false)
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

    /// Destroys this device's identity key and mints a fresh one under a new device ID.
    ///
    /// Both, not just the key. A Mac that already holds a pin for this client ID will only
    /// ever accept the key it pinned, so rotating the key alone locks the device out of every
    /// Mac it has paired with. Changing the ID as well makes this device a stranger again,
    /// which is what "start over" has to mean.
    /// Destroys this device's identity key and mints a fresh one under a new device ID.
    ///
    /// Both, not just the key. A Mac that already holds a pin for this client ID will only
    /// ever accept the key it pinned, so rotating the key alone locks the device out of every
    /// Mac it has paired with. Changing the ID as well makes this device a stranger again,
    /// which is what "start over" has to mean.
    func resetDeviceIdentity() {
        session?.disconnect()
        session = nil
        // The phase moves off `.ready` here rather than through `apply(_:)`, so the elapsed
        // time has to be cleared here too or the readout would outlive its session.
        sessionStartedAt = nil
        phase = .disconnected
        do {
            try SelfSignedIdentity.destroy(role: .client)
        } catch {
            append(note: "Could not destroy the old key: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            return
        }
        _ = pins.removeAll()

        UserDefaults.standard.removeObject(forKey: "Peering.deviceID")
        device = DeviceIdentity.loadOrCreate(defaultName: Self.defaultDeviceName)

        do {
            self.identity = try SelfSignedIdentity.loadOrCreate(role: .client, commonName: device.name)
            append(note: "New identity \(device.id.prefix(8))…. Pair again on the Mac.")
        } catch {
            identityFailure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        device.saveName(trimmed)
        device = DeviceIdentity.loadOrCreate(defaultName: trimmed)
    }

}
