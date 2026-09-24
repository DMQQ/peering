import MacCastKit
import RemoteCore
import SwiftUI

/// Pairing, connecting, and getting back to a Mac. An extension on the model rather than a type of
/// its own, because this state is the model's.
extension SessionModel {
    /// What this device can say about what it bought, in the shape the relay asks for it.
    ///
    /// Built in one place because a call site that forgets part of it counts a paying subscriber down
    /// at the free allowance. The receipt is the part that matters: the relay verifies it against
    /// Apple's root and meters by the product it names, and the plan beside it is read only when there
    /// is no receipt to check, which is the case for an older app and for the moment before
    /// ``StoreManager/start()`` has asked the App Store what is current. See ``RelayEntitlement``.
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
    /// The one path into a Mac with no pin behind it, and the licence is the user: every other route in
    /// insists on a stored pin for the ID, because each is the app acting on its own about a Mac it
    /// already knows, while here the user has just read a device ID off the other machine. The guard is
    /// answered rather than relaxed: the Mac still asks both people to compare six digits, and that
    /// comparison is what authorises the pairing. The ID only decided who was asked. See
    /// ``ClientSession/Target/relayPairing(hostID:name:entitlement:)``.
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
            // Unreachable: `PairingPayload` reports every refusal as one of its own cases. The field
            // is the user's text, so something has to be said about it either way.
            return .notAnIdentifier(text)
        }

        guard allowsRelay else {
            // A setting the user turned off rather than a failure of the pairing. Said here as well
            // because this path cannot work without it: the Mac is not on this network, so there is no
            // second route to try.
            append(note: "Remote access is turned off in Settings, so a Mac on another network cannot be reached.")
            return nil
        }

        // Named "A Mac" until the handshake says otherwise: a first pairing has not been told what the
        // Mac calls itself, and the ID is not a name.
        connect(to: relayPairingTarget(hostID: hostID, name: "A Mac"))
        return nil
    }

    func confirmPairing(accepted: Bool) {
        // Declining ends the session from the Mac's side too, and that arrives as a `.disconnected`
        // like any other, so without this the user's own "no" comes back to them as a lost connection.
        //
        // The *session* object and not the wire: what this records is about the Mac, not the
        // connection the frame goes out on.
        if !accepted { activeSession?.userEndedDeliberately = true }
        session?.confirmPairing(accepted: accepted)
    }

    /// Ends the session now.
    ///
    /// `deliberate` answers "did the user mean to do this", which is not the same question as "who
    /// called this function". A disconnect the user tapped is silent; one iOS forced because it is
    /// about to suspend the app is not, because a banner is the only way they will hear about it.
    func disconnect(deliberate: Bool = true) {
        // Taken first: the card that outlives a non-deliberate end needs both to say what was lost,
        // and after the lines below they are simply nil.
        let wasStartedAt = sessionStartedAt
        let wasPath = MacSession.activityPath(connectionPath)

        // Only for a deliberate end. A drop, and the end iOS forces on a backgrounded app, are the two
        // cases where coming back to the app should find the session restored.
        if deliberate { UserDefaults.standard.set(false, forKey: Self.resumeKey) }

        // Every Mac, not the one on screen: the control says "Disconnect", and the end iOS forces is
        // for the whole process, with every session suspended with it. See ``backgroundTimeExpired()``.
        //
        // The answer is handed to each Mac rather than kept in one place for them to share: a single
        // record of "the user meant this" is consumed by whichever session answers first, and the rest
        // would be read as having dropped and would arm a ladder that can never finish. See
        // ``MacSession/userEndedDeliberately``.
        for session in sessions { session.endSession(deliberate: deliberate) }

        // The arrangement is forgotten when the user says they are done with this Mac: it is remembered
        // for coming back to it, and a user who pressed Disconnect has said the opposite. Keeping it left
        // them with a mosaic that reappeared on every connection. See ``MosaicArrangementStore``.
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
        // Detached only for a deliberate end. A non-deliberate one is followed by the reconnect ladder
        // and the RemoteScreen is deliberately kept mounted across it: detaching severs the renderer
        // from that still-mounted view, and SwiftUI does not call `makeUIView` again, so a healthy new
        // connection would have every frame disappear into no display.
        if deliberate { renderer.detach() }
        // Nothing is open any more, which is the widget's business as much as the card's.
        publishOpenMacs()
        // An end this app chose is not a session the relay cut. Cleared here as well as on a session
        // coming up, because this path sets the phase directly and so never passes through the drop
        // handling that would clear it.
        relaySessionDropped = false
        latchedModifiers = []
        // Nothing is on screen to have stepped away from, and the session after this one takes the
        // screen from the start. See ``isSessionOnScreen``.
        isSessionOnScreen = true
        pausedBySteppingAway = false

        // This method is how both a deliberate and a forced end arrive, so which announcement is made
        // turns on `deliberate`: backgrounding the app must not make the card vanish as though the user
        // had quit.
        //
        // The keepalive and the floating window go with the session, and this method has to do that
        // itself for the same reason the card does: it sets the phase rather than letting the event path
        // announce it, so nothing that hangs off a phase *change* runs.
        SessionAudio.shared.end()
        SessionPiP.shared.detach()

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

    /// Ends one Mac's session, and hands the picture over if it was the one on screen.
    ///
    /// The picture, the sound, the floating window and the Live Activity are singular and belong to
    /// whichever Mac is being looked at, so ending that Mac gives them to the next one: leaving them
    /// pointed at a stopped session would have the screens go on drawing a Mac that is gone, and the
    /// strip show a selection with no tab to match it. Ending a Mac that is not on screen needs none of
    /// that.
    func endSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }

        // Cleared before the teardown, so what follows reads as a switch *out of* a session rather than
        // into one: ``activateSession(_:)`` is a no-op for the Mac already on screen, and the Mac being
        // ended is still that until this line runs.
        let wasActive = activeSessionID == id
        if wasActive { activeSessionID = nil }

        // The user asked for this one: `wire` announces its own end and the phases are already where they
        // are by the time it arrives, so this is the only evidence that the user rather than the network
        // ended it. See ``MacSession/userEndedDeliberately``.
        session.endSession(deliberate: true)

        guard wasActive else {
            publishOpenMacs()
            return
        }

        if let next = openSessions.first {
            activateSession(next.id)
        } else {
            // Nothing left to hand to: these are one of each for the whole app, and a Mac nobody is
            // connected to must not be left owning any of them.
            renderer.detach()
            SessionAudio.shared.end()
            SessionPiP.shared.detach()
            SessionActivity.shared.sessionEnded()
            publishOpenMacs()
        }
    }

    /// Connects to a Mac this device has paired with before, by ID.
    ///
    /// Bonjour wins when it has the Mac, preserving the direct LAN path. Otherwise the same stable host
    /// ID is sent to the relay; no remembered IP address is involved.
    func connectToTrusted(hostID: String) {
        if let host = hosts.first(where: { $0.id == hostID }) {
            pendingHostID = nil
            connect(to: .discovered(host))
            return
        }
        guard allowsRelay else {
            // Waited for rather than refused: the Mac is paired, and the only thing missing is that it
            // is not on this network yet. That is a state that ends by itself, when it walks back into
            // range or the Mac wakes, and the browser's next update connects with no further tap.
            pendingHostID = hostID
            return
        }
        pendingHostID = nil
        connect(to: relayTarget(hostID: hostID, name: displayName(forHostID: hostID) ?? "A Mac"))
    }

    /// Explicit route choices from the trusted-Mac row. Unlike a regular row tap these do not fall back
    /// to the other transport.
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

    /// Where the name of the last Mac this device connected to is kept: `UserDefaults` rather than the
    /// app group a widget would have to read, because the widget does not need to know *which* Mac,
    /// only that there is one to offer. That keeps a shared container and its provisioning out of a
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

    /// Reconnects to the Mac this device used last. A matching Bonjour result uses the direct LAN path;
    /// a trusted ID that is not currently visible uses the relay.
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

    /// Whether the next sight of the last Mac should put the session back, and the putting back itself.
    ///
    /// Written down rather than remembered, because the case that matters most is the one where iOS
    /// killed the app while it was backgrounded: nothing of the session survives that, so "there was
    /// one" has to have been recorded before it happened. A deliberate disconnect clears the flag and
    /// nothing here fires; a dropped connection leaves it set.
    ///
    /// Called from three places because they cover different arrivals: coming back to the front, a host
    /// appearing, and the ladder's own tick.
    // MARK: - Relay presence

    /// Asks the relay which of the paired Macs are up, and takes the answer as the whole truth.
    ///
    /// An empty answer is not news: `hostPresence` returns nothing both when the relay answered with an
    /// error and when the network was down, and neither is the relay saying every Mac has gone, so a
    /// round that learned nothing leaves what was known standing.
    ///
    /// Called by the Connect tab while it is on screen. Nothing polls in the background: a phone that
    /// asked after its Macs from a pocket would be telling the relay where its owner is for no one's
    /// benefit.
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

        // Replaced rather than merged: a Mac that has gone is *absent* from the answer, and merging
        // would leave a stale `true` on the row of a Mac that is switched off.
        relayPresence = answers
    }

    /// Puts every Mac that has dropped back, and starts the one that was open last if none is.
    ///
    /// Each session resumes itself, see ``MacSession/resumeIfNeeded()``; what is left here is the launch
    /// where there is no session at all and the only evidence of one is what was written down before the
    /// app died.
    func resumeIfNeeded() {
        for session in sessions { session.resumeIfNeeded() }
        resumeTheLastMacIfNothingIsOpen()
    }

    /// The cold launch: nothing is open, and `resumeKey` says there was something.
    ///
    /// A separate path rather than a branch of the loop above, because a session that does not exist yet
    /// cannot know which Mac it is for: the ID is in the defaults and nowhere else. It is also the only
    /// case where Bonjour can be consulted by *name*.
    private func resumeTheLastMacIfNothingIsOpen() {
        // Only the launch with nothing in it: with a session object at all, the loop above has already
        // asked that session to put itself back, and a second dial for the same Mac would race the first
        // and close its connection mid-handshake.
        guard sessions.isEmpty else { return }
        guard UserDefaults.standard.bool(forKey: Self.resumeKey) else { return }

        let defaults = UserDefaults.standard
        let hostID = defaults.string(forKey: Self.lastHostIDKey)
        let name = defaults.string(forKey: Self.lastHostNameKey)
        if let host = hosts.first(where: { hostID != nil ? $0.id == hostID : $0.name == name }) {
            isResuming = true
            connect(to: .discovered(host))
        } else if let hostID, allowsRelay, pins.hostIDs.contains(hostID) {
            isResuming = true
            connect(to: relayTarget(hostID: hostID, name: name ?? displayName(forHostID: hostID) ?? "A Mac"))
        }
    }

    /// Opens a Mac that is already paired, beside the ones already open.
    ///
    /// The door the strip's `+` and the picker's rows both come through. The gate and the ceiling are
    /// enforced one level down in ``SessionModel/connect(to:replacing:)``, where every route from
    /// anywhere in the app arrives; this is where the "already open" question is answered.
    func addSession(hostID: String) {
        // A Mac already open is brought to the front rather than opened twice: two sessions to one Mac
        // would be two control channels and two clients on the Mac, for one phone.
        if let open = sessions.first(where: { $0.hostID == hostID && $0.isLive }) {
            activateSession(open.id)
            return
        }
        connect(to: relayTarget(hostID: hostID, name: displayName(forHostID: hostID) ?? "A Mac"))
    }

    /// The paired Macs that are not already open, which is what the strip's `+` offers. Most recently
    /// connected first, since the Mac someone wants to add is almost always one they have used lately.
    var closedPairedMacs: [(id: String, name: String)] {
        let open = Set(sessions.compactMap(\.hostID))
        return pairedHostIDs
            .filter { !open.contains($0) }
            .sorted { (lastConnectedAt[$0] ?? .distantPast) > (lastConnectedAt[$1] ?? .distantPast) }
            .map { (id: $0, name: displayName(forHostID: $0) ?? "A Mac") }
    }

    /// Replaces one Mac's session with a fresh attempt at the same Mac, and leaves the rest alone.
    ///
    /// The old session is removed rather than left to be pruned: it is the one being replaced and its
    /// ladder has just handed over, and leaving it would put two entries for one Mac in the strip for as
    /// long as the new attempt takes, which reads as "it connected twice".
    func reconnect(_ session: MacSession, to target: ClientSession.Target) {
        connect(to: target, replacing: session)
    }

    /// Stops the active Mac being retried, *without* resetting its backoff.
    ///
    /// The counter belongs to a run of attempts, and resetting it here is what turns a failing reconnect
    /// into a permanent loop: the attempt count returns to zero and the delays never advance past the
    /// first second. Only a session that actually came up clears it, in the `.ready` branch of
    /// ``MacSession/apply(_:)``.
    func stopReconnecting() { activeSession?.stopReconnecting() }

    // MARK: - Backgrounding

    /// Tells the object that floats the picture whether the plan includes it, and answers the same
    /// question for the caller.
    ///
    /// One writer, called wherever the answer can change: when the entitlement first lands, whenever it
    /// changes under a running app, and as the app leaves the screen. It is a function rather than a line
    /// at each of those sites because the one easy to leave out is the launch, and a controller armed
    /// before the App Store answered would be armed with the wrong answer for the rest of the session.
    /// See ``SessionPiP/isOnPlan``.
    @discardableResult
    func applyPictureInPicturePlan() -> Bool {
        let included = PictureInPictureAccess.canArm(access: storeManager.access)
        SessionPiP.shared.isOnPlan = included
        return included
    }

    /// Tells the object that raises terminal banners whether the plan includes them, and answers the same
    /// question for the caller.
    ///
    /// Its twin, called from the same moments. A push rather than a read, because the object it informs
    /// owns no store, the same arrangement ``SessionPiP`` is kept in; the other half of the feature is the
    /// registration refused in ``sendPushToken()``, which has the store in front of it.
    ///
    /// The banner it gates has no tap to wait for, so failing closed until the answer is known costs a
    /// subscriber one banner in the first moments of a launch.
    @discardableResult
    func applyTerminalAlertPlan() -> Bool {
        let included = TerminalAlertsAccess.canNotify(access: storeManager.access)
        SessionNotifier.shared.isOnPlan = included
        return included
    }

    func setPiPAutoStart(_ on: Bool) { SessionPiP.shared.autoStart = on }

    /// Called when the app is backgrounded with a session up.
    ///
    /// There is no background mode a remote desktop can honestly claim, so this is the whole of the
    /// reprieve: it buys the few seconds that make switching to another app for something and coming
    /// straight back survivable, and nothing beyond that.
    func enteringBackground() {
        SessionActivity.shared.enteringBackground()

        // The plan, pushed into the singleton before it is asked to float anything: the picture is drawn
        // by an object that owns no store. Written on every backgrounding rather than once, because an
        // entitlement can arrive or lapse while the app runs.
        //
        // The switch's own preference is not pushed from here: it belongs to ``SessionPiP``, and a third
        // copy would be a third place for it to disagree.
        let pipIncluded = applyPictureInPicturePlan()

        // And the other thing allowed to arrive on its own: a shell that stops while the app is not on
        // screen raises its banner rather than waiting for a tap, so the answer it reads has to be
        // current.
        applyTerminalAlertPlan()

        // A shell the user is leaving with a prompt still open. The Mac's detector fires once, when the
        // prompt appears, and this side says nothing while the app is in front of the user, so without
        // this that prompt could never reach a banner. See
        // ``SessionNotifier/terminalStillWaiting(_:name:sessionID:macName:)``.
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

        // Started here rather than left to `canStartPictureInPictureAutomaticallyFromInline`: that flag
        // is set, but iOS never takes the hint, because automatic PiP is gated on the system considering
        // the app to be *playing*, and an `AVAudioPlayer` running silence is not counted.
        //
        // The moment matters as well: this runs as the app leaves the screen, when
        // `startPictureInPicture` still has a view hierarchy to lift the layer out of.
        //
        // `false` for a plan without it, which reads in ``SessionPiP`` as "no session up" and is the
        // honest answer: there is nothing here to float.
        SessionPiP.shared.backgrounding(sessionIsUp: phase.holdsSession && pipIncluded)

        // Held while any Mac is open or being retried: what iOS suspends is the process, so the
        // assertion is about the app rather than the Mac on screen. A LAN session that drops moves to
        // `.failed` before `enteringBackground()`, so without this the app suspends, `Task.sleep`
        // freezes, and the "dropped" Live Activity card is never shown.
        guard hasOpenSession, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Peering session") { [weak self] in
            Task { @MainActor in self?.backgroundTimeExpired() }
        }
    }

    func enteringForeground() {
        // If the card is still showing the Mac as dropped from the background timeout, and that
        // Mac is already back within reach, jump straight to "reconnecting" instead of leaving
        // "dropped" up for the round trip `resumeIfNeeded()` below is about to make. The check is
        // ``reachability(ofHost:)``, the same one the picker's own dot reads, so the two agree the
        // moment the app is back on screen rather than a beat later while the dial is in flight.
        if let session = activeSession,
           !session.phase.holdsSession,
           !session.userEndedDeliberately,
           let hostID = session.hostID,
           reachability(ofHost: hostID).isReachable {
            SessionActivity.shared.showReconnecting(
                hostName: session.hostName ?? "the Mac",
                startedAt: session.sessionStartedAt,
                path: MacSession.activityPath(session.connectionPath)
            )
        } else {
            SessionActivity.shared.returningToForeground()
        }
        endBackgroundAssertion()

        // The App Store's answer, re-read before anything is armed from it again: a subscription that ran
        // out while the app was off screen produced no transaction to notice it by, so the plan this
        // process holds can be hours out of date, and every gate reads it. Asked here because the reading
        // is local and this is the one point where waiting for it costs nothing.
        Task { await storeManager.rereadEntitlement() }
        // A browse that died while the app was in the background has been sitting behind its own backoff
        // in a suspended process, so starting one now is the difference between a list that is there when
        // the user looks and one that fills in several seconds later.
        if browseFailed { restartBrowsing() }
        // **The ladder's pending wait is cut short before it is consulted.** A Mac partway through a
        // rung would otherwise spend the rest of it in front of the user, waiting for time that has
        // already passed. See ``MacSession/resumeWithoutWaiting()``.
        for session in sessions { session.resumeWithoutWaiting() }
        resumeIfNeeded()
        // The layer's contents do not survive the background and the host sends nothing new for a Mac
        // that has not changed, so this is what brings the picture back. See
        // ``VideoRenderer/repaintAfterForegrounding()``.
        activeSession?.renderer.repaintAfterForegrounding()
    }

    /// Ends the session when the background window runs out, rather than letting the system kill it.
    ///
    /// The Live Activity is taken down and the Mac is told the session is over, instead of a Lock Screen
    /// card claiming a connection that ended, which nothing of ours is running to correct. And the user,
    /// who is not looking, gets a banner.
    func backgroundTimeExpired() {
        let shouldEndSession = BackgroundSessionExpiry.shouldEndSession(
            assertionIsActive: backgroundTask != .invalid,
            appIsBackground: UIApplication.shared.applicationState == .background,
            hasOpenSession: hasOpenSession,
            // PiP is a system-owned background presentation: once it is active iOS is keeping the app
            // alive for real media playback, and the temporary assertion expiring must not tear down the
            // session underneath the floating window.
            pictureInPictureIsActive: SessionPiP.shared.isActive
        )
        endBackgroundAssertion()
        // Every Mac, in one call because ``disconnect(deliberate:)`` already means all of them: a Mac
        // behind the active one would otherwise be left to be killed unobserved. The card and the banner
        // are taken down by the same path, which is why this ends the session tidily rather than letting
        // the system do it.
        guard shouldEndSession else { return }
        disconnect(deliberate: false)
    }

    func endBackgroundAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Forgets the pin for a Mac. The Mac keeps its half, so the next connection is refused by it until
    /// it is unpaired on that side too, which is the honest behaviour for "forget" rather than a silent
    /// re-pair.
    func forget(hostID: String) {
        pins.remove(hostID: hostID)
        pairedHostIDs = pins.hostIDs
        publishKnownMacs()
        append(note: "Forgot \(hostID). Unpair this device on the Mac as well.")
    }

    // A `resetDeviceIdentity()` belongs here again only alongside a quota the relay counts against
    // something a reset cannot change: the relay counts relay time per client ID, so it would hand the
    // caller a fresh allowance, a day's worth per tap, whatever the plan said.

    func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        device.saveName(trimmed)
        device = DeviceIdentity.loadOrCreate(defaultName: trimmed)
    }

}
