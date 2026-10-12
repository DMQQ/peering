import MacCastKit
import RemoteCore
import SwiftUI

extension SessionModel {
    /// Built in one place because a call site that forgets part of it counts a paying subscriber at the free allowance. The relay verifies the receipt; the plan is read only when there is none.
    var relayEntitlement: RelayEntitlement {
        RelayEntitlement(
            plan: storeManager.relayPlan.rawValue,
            jwsRepresentation: storeManager.activeJWS,
            apiKey: storeManager.apiKey
        )
    }

    func relayTarget(hostID: String, name: String) -> ClientSession.Target {
        .relay(hostID: hostID, name: name, entitlement: relayEntitlement)
    }

    func relayPairingTarget(hostID: String, name: String) -> ClientSession.Target {
        .relayPairing(hostID: hostID, name: name, entitlement: relayEntitlement)
    }

    /// A Mac's own QR code, scanned with the system camera. A Mac on this network is dialled directly, because the relay is for a Mac that cannot be reached any other way and costs the free allowance; only a Mac that is not here goes through it.
    func openHostLink(hostID: String) {
        if pairedHostIDs.contains(hostID) {
            connectToTrusted(hostID: hostID)
        } else if let host = hosts.first(where: { $0.id == hostID }) {
            connect(to: .discovered(host))
        } else {
            pairWithRemoteMac(hostID: hostID)
        }
    }

    /// The one path into a Mac with no pin behind it: the user has just read a device ID off the other machine. The guard is answered, not relaxed: the Mac still asks both people to compare six digits.
    @discardableResult
    func pairWithRemoteMac(hostID text: String) -> PairingPayloadError? {
        Analytics.featureUsed(.remotePairingStarted)
        let hostID: String
        do {
            hostID = try PairingPayload.hostID(from: text)
        } catch let problem as PairingPayloadError {
            Analytics.pairingInputRefused(problem, stage: .codeEntry)
            return problem
        } catch {
            // Unreachable: `PairingPayload` reports every refusal as its own case.
            return .notAnIdentifier(text)
        }

        guard allowsRelay else {
            // A setting the user turned off, said here too because this path cannot work without it.
            append(note: String(localized: "Remote access is turned off in Settings, so a Mac on another network cannot be reached."))
            return nil
        }

        connect(to: relayPairingTarget(hostID: hostID, name: String(localized: "A Mac")))
        return nil
    }

    func confirmPairing(accepted: Bool, secret: Data? = nil) {
        // Declining ends the session from the Mac's side too and arrives as `.disconnected`, so without this the user's own "no" reads as a lost connection.
        if !accepted { activeSession?.userEndedDeliberately = true }
        Analytics.pairingDecided(accepted: accepted)
        if !accepted { Analytics.pairingFailed(stage: .confirm, reason: "cancelled") }
        PostHogLog.info("pairing decision submitted", attributes: [
            "pairing_outcome": accepted ? "accepted" : "declined",
        ])
        session?.confirmPairing(accepted: accepted, secret: secret)
    }

    /// `deliberate` is "did the user mean it", not "who called": a tapped disconnect is silent, one iOS forced is not, since a banner is the only way they hear of it.
    func disconnect(deliberate: Bool = true, endReason: SessionEndReason = .backgrounded) {
        // Taken first: the card that outlives a non-deliberate end needs both, and below they are nil.
        let wasStartedAt = sessionStartedAt
        let wasPath = MacSession.activityPath(connectionPath)
        let analyticsPath = connectionPath?.rawValue ?? "unknown"

        // Only for a deliberate end: a drop and the end iOS forces should find the session restored on return.
        if deliberate { UserDefaults.standard.set(false, forKey: Self.resumeKey) }

        // Every Mac, not the one on screen: the forced end is for the whole process.
        // Handed to each Mac rather than shared: a single record of "the user meant this" is consumed by the first session to answer, and the rest would arm a ladder that can never finish.
        for session in sessions {
            session.reportEnd(deliberate ? .user : endReason)
            session.endSession(deliberate: deliberate)
        }

        // Forgotten on Disconnect: it is kept for coming back, and a user who disconnected said the opposite (it made a mosaic reappear on every connection).
        if deliberate {
            for session in sessions {
                if let hostID = session.hostID { MosaicArrangementStore.save([], hostID: hostID) }
                session.mosaicViewportTask?.cancel()
                session.mosaicViewportTask = nil
                session.mosaicGapTask?.cancel()
                session.mosaicGapTask = nil
                session.mosaicChoices = []
                session.isAskingForMosaic = false
                session.pictureMosaicLayout = nil
            }
        }
        // Detached only for a deliberate end: the RemoteScreen stays mounted across the reconnect ladder, and detaching severs the renderer from it since SwiftUI does not call `makeUIView` again.
        if deliberate { renderer.detach() }
        publishOpenMacs()
        // An end this app chose is not a session the relay cut. Cleared here too because this path never passes through the drop handling.
        relaySessionDropped = false
        latchedModifiers = []
        isSessionOnScreen = true
        pausedBySteppingAway = false

        // Both a deliberate and a forced end arrive here, so the announcement turns on `deliberate`: backgrounding must not make the card vanish as if the user quit.
        // This sets the phase itself, so nothing hanging off a phase change runs: the keepalive and floating window go here.
        SessionAudio.shared.end()
        SessionPiP.shared.detach()

        if deliberate {
            PostHogLog.info("session disconnect requested", attributes: [
                "connection_path": analyticsPath,
            ])
            SessionActivity.shared.sessionEnded()
        } else {
            SessionActivity.shared.sessionDropped(
                hostName: hostName ?? String(localized: "the Mac"),
                startedAt: wasStartedAt,
                path: wasPath
            )
        }
    }

    /// The picture, sound, floating window and Live Activity are singular, so ending the Mac on screen hands them to the next; leaving them on a stopped session would keep drawing a gone Mac.
    func endSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }

        // Cleared before the teardown so it reads as a switch out of a session: `activateSession(_:)` is a no-op for the Mac already on screen.
        let wasActive = activeSessionID == id
        if wasActive { activeSessionID = nil }

        // The only evidence that the user, not the network, ended it: `wire` announces its own end after the phases have moved.
        session.reportEnd(.user)
        session.endSession(deliberate: true)

        guard wasActive else {
            publishOpenMacs()
            return
        }

        if let next = openSessions.first {
            activateSession(next.id)
        } else {
            renderer.detach()
            SessionAudio.shared.end()
            SessionPiP.shared.detach()
            SessionActivity.shared.sessionEnded()
            publishOpenMacs()
        }
    }

    /// Opens the Mac a tapped notification came from and, when it names one, the window it is about.
    func openFromNotification(hostID: String, sourceID: String?) {
        guard pairedHostIDs.contains(hostID) else { return }
        if let open = sessions.first(where: { $0.hostID == hostID && $0.isLive }) {
            activateSession(open.id)
            isSessionOnScreen = true
            guard let sourceID else { return }
            if let descriptor = open.catalog?.all.first(where: { $0.id == sourceID }) {
                selectSource(descriptor)
            } else {
                // Not listed yet, so asked for when the next catalogue arrives.
                open.sourceRequestedOnOpen = sourceID
            }
            return
        }
        let before = activeSessionID
        connectToTrusted(hostID: hostID)
        if let sourceID, activeSessionID != before {
            activeSession?.sourceRequestedOnOpen = sourceID
        }
    }

    func connectToTrusted(hostID: String) {
        if let host = hosts.first(where: { $0.id == hostID }) {
            pendingHostID = nil
            connect(to: .discovered(host))
            return
        }
        guard allowsRelay else {
            // Waited for rather than refused: the Mac is paired and merely not on this network yet, a state that ends by itself when the browser next updates.
            pendingHostID = hostID
            return
        }
        pendingHostID = nil
        connect(to: relayTarget(hostID: hostID, name: displayName(forHostID: hostID) ?? String(localized: "A Mac")))
    }

    /// Explicit route choices from the trusted-Mac row do not fall back to the other transport.
    func connectToTrustedOverLAN(hostID: String) {
        guard let host = hosts.first(where: { $0.id == hostID }) else { return }
        pendingHostID = nil
        connect(to: .discovered(host))
    }

    func connectToTrustedOverRelay(hostID: String) {
        guard allowsRelay, pins.hostIDs.contains(hostID) else { return }
        pendingHostID = nil
        connect(to: relayTarget(hostID: hostID, name: displayName(forHostID: hostID) ?? String(localized: "A Mac")))
    }

    // MARK: - Quick connect

    /// `UserDefaults` rather than the app group: the widget only needs to know there is one Mac to offer, which keeps a shared container out of the feature.
    func connectToManualAddress() {
        Analytics.featureUsed(.manualAddressConnect)
        guard let port = UInt16(manualPort.trimmingCharacters(in: .whitespaces)) else {
            append(note: String(localized: "“\(manualPort)” is not a port number."))
            return
        }
        let host = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        connect(to: .address(host: host, port: port))
    }

    func reconnectToLastHost() {
        guard !phase.holdsSession else { return }
        let defaults = UserDefaults.standard
        let hostID = defaults.string(forKey: Self.lastHostIDKey)
        let name = defaults.string(forKey: Self.lastHostNameKey)
        if let host = hosts.first(where: { hostID != nil ? $0.id == hostID : $0.name == name }) {
            connect(to: .discovered(host))
        } else if let hostID, allowsRelay, pins.hostIDs.contains(hostID) {
            connect(to: relayTarget(hostID: hostID, name: name ?? displayName(forHostID: hostID) ?? String(localized: "A Mac")))
        }
    }

    /// Written down because iOS may kill the app while backgrounded and nothing of the session survives. A deliberate disconnect clears it; a drop leaves it set.
    // MARK: - Relay presence

    /// An empty answer is not news: `hostPresence` returns nothing on an error or no network, so a round that learned nothing leaves what was known.
    /// Called by the Connect tab while on screen; nothing polls in the background.
    func refreshRelayPresence() async {
        let hostIDs = pairedHostIDs
        guard !hostIDs.isEmpty, allowsRelay else {
            if !allowsRelay { relayPresence.removeAll() }
            return
        }

        let (answers, reachable) = await RelaySignallingConnection.hostPresence(
            at: ProtocolInfo.relaySignallingURL,
            hostIDs: hostIDs
        )
        relayReachable = reachable
        guard !answers.isEmpty else { return }

        // Replaced rather than merged: a Mac that has gone is absent from the answer, and merging would leave a stale `true`.
        relayPresence = answers
    }

    func resumeIfNeeded() {
        for session in sessions { session.resumeIfNeeded() }
        resumeTheLastMacIfNothingIsOpen()
    }

    /// A separate path: a session that does not exist yet cannot know which Mac it is for, and this is the only case where Bonjour is consulted by name.
    private func resumeTheLastMacIfNothingIsOpen() {
        // Only the launch with nothing in it: otherwise a second dial for the same Mac would race the first and close its connection mid-handshake.
        guard sessions.isEmpty else { return }
        guard UserDefaults.standard.bool(forKey: Self.resumeKey) else { return }

        let defaults = UserDefaults.standard
        let hostID = defaults.string(forKey: Self.lastHostIDKey)
        let name = defaults.string(forKey: Self.lastHostNameKey)
        if let host = hosts.first(where: { hostID != nil ? $0.id == hostID : $0.name == name }) {
            isResuming = true
            connect(to: .discovered(host))
            return
        }

        guard let hostID else { return }

        // Dialled at once and raced against the relay, so a relaunch does not wait for Bonjour.
        if let remembered = rememberedLANHost(hostID), pins.hostIDs.contains(hostID) {
            isResuming = true
            let relay = allowsRelay
                ? relayTarget(hostID: hostID, name: name ?? displayName(forHostID: hostID) ?? String(localized: "A Mac"))
                : nil
            connect(to: .discovered(remembered), replacing: nil, timeout: Self.rememberedPathTimeout, racingRelay: relay)
            return
        }

        guard allowsRelay, pins.hostIDs.contains(hostID) else { return }

        // The same grace `enteringForeground()` gives, for a cold launch: dialling the relay before Bonjour's first sweep sent phones past a Mac on their own LAN, since the relay session gets a picture and the LAN handover's `!hasHadPicture` guard never fires.
        let elapsedMilliseconds = Date().timeIntervalSince(launchedAt) * 1000
        guard elapsedMilliseconds >= Double(Self.localMacGrace) else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(
                    Self.localMacGrace - Int(elapsedMilliseconds)
                ))
                self?.resumeIfNeeded()
            }
            return
        }

        isResuming = true
        connect(to: relayTarget(hostID: hostID, name: name ?? displayName(forHostID: hostID) ?? String(localized: "A Mac")))
    }

    func addSession(hostID: String) {
        // Brought to the front rather than opened twice: two sessions would be two clients on the Mac.
        if let open = sessions.first(where: { $0.hostID == hostID && $0.isLive }) {
            activateSession(open.id)
            return
        }
        if let host = hosts.first(where: { $0.id == hostID }) {
            connect(to: .discovered(host))
        } else if let remembered = rememberedLANHost(hostID) {
            connect(to: .discovered(remembered), replacing: nil, timeout: Self.rememberedPathTimeout)
        } else {
            connect(to: relayTarget(hostID: hostID, name: displayName(forHostID: hostID) ?? String(localized: "A Mac")))
        }
    }

    /// Most recently connected first.
    var closedPairedMacs: [(id: String, name: String)] {
        let open = Set(sessions.compactMap(\.hostID))
        return pairedHostIDs
            .filter { !open.contains($0) }
            .sorted { (lastConnectedAt[$0] ?? .distantPast) > (lastConnectedAt[$1] ?? .distantPast) }
            .map { (id: $0, name: displayName(forHostID: $0) ?? String(localized: "A Mac")) }
    }

    /// The old session is removed rather than pruned: leaving it shows two entries for one Mac and reads as "it connected twice".
    func reconnect(
        _ session: MacSession,
        to target: ClientSession.Target,
        timeout: TimeInterval = SessionModel.standardConnectTimeout,
        racingRelay relay: ClientSession.Target? = nil
    ) {
        connect(to: target, replacing: session, timeout: timeout, racingRelay: relay)
    }

    /// Without resetting the backoff: resetting it turns a failing reconnect into a permanent loop with delays never past the first second. Only `.ready` clears it.
    func stopReconnecting() { activeSession?.stopReconnecting() }

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
        tellMacsAppIsBackground(true)
    }

    /// Picture in Picture keeps the app alive and drawing, so the Mac must keep sending while it is up.
    func pictureInPictureChanged(active: Bool) {
        tellMacsAppIsBackground(!active && UIApplication.shared.applicationState != .active)
    }

    private func tellMacsAppIsBackground(_ background: Bool) {
        for session in sessions { session.wire?.sendClientState(background: background) }
    }

    // Held while any Mac is open or retrying: iOS suspends the process, and a LAN session that drops to `.failed` before `enteringBackground()` would freeze `Task.sleep` and never show the "dropped" card.
    private func beginBackgroundGrace() {
        guard hasOpenSession, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: String(localized: "Peering session")) { [weak self] in
            Task { @MainActor in self?.backgroundTimeExpired() }
        }
    }

    func enteringForeground() {
        tellMacsAppIsBackground(false)
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

    private static let localMacGrace = 900

    private func resumeEveryMac() {
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

    /// The Mac keeps its half, so the next connection is refused by it until unpaired there too: the honest behaviour for "forget".
    func forget(hostID: String) {
        Analytics.featureUsed(.macForgotten)
        pins.remove(hostID: hostID)
        pairedHostIDs = pins.hostIDs
        publishKnownMacs()
        append(note: String(localized: "Forgot \(hostID). Unpair this device on the Mac as well."))
    }

    // A `resetDeviceIdentity()` belongs here only alongside a quota the relay cannot reset per client ID: it would hand out a fresh allowance per tap.

    func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        device.saveName(trimmed)
        device = DeviceIdentity.loadOrCreate(defaultName: trimmed)
    }

}
