import MacCastKit
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
        //
        // The *session* object and not the wire: `session` here is the `ClientSession` the frame
        // goes out on, and what this records is about the Mac it belongs to.
        if !accepted { activeSession?.userEndedDeliberately = true }
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
        let wasPath = MacSession.activityPath(connectionPath)

        // Only a deliberate one. A drop, and the end iOS forces on a backgrounded app, are the
        // two cases where coming back to the app should find the session restored.
        if deliberate { UserDefaults.standard.set(false, forKey: Self.resumeKey) }

        // **Every Mac, not the one on screen.** The control says "Disconnect", and a person
        // saying that to their phone means stop rather than stop one of the things it is doing.
        // The end iOS forces is the same argument from the other side: it granted a few seconds
        // for the whole process and every session is about to be suspended with it, so ending
        // one and leaving the rest to be killed unobserved is the worst of the three outcomes.
        // See ``backgroundTimeExpired()``.
        // **The answer is handed to each Mac rather than kept in one place for them to share.**
        // Each one answers with its own transition afterwards, and a single record of "the user
        // meant this" is consumed by whichever answers first: the rest would be read as having
        // dropped and would arm a ladder that can never finish, leaving them in the strip as tabs
        // that never come back. See ``MacSession/userEndedDeliberately``.
        for session in sessions { session.endSession(deliberate: deliberate) }

        // **The arrangement is forgotten when the user says they are done with this Mac.** What
        // the arrangement is remembered *for* is coming back to it: a phone that dropped, or that
        // iOS suspended, should find the windows it was looking at still arranged. A user who
        // pressed Disconnect has said the opposite — they are finished with these windows — and
        // what they were left with otherwise was an arrangement that reappeared on every
        // connection and could not be got rid of: asking for a single display was answered with
        // the mosaic again the next time the app opened. See ``MosaicArrangementStore``.
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
        // A non-deliberate end is followed by the reconnect ladder, and the RemoteScreen is
        // deliberately kept mounted across that handover. Detaching here severs the renderer
        // from that still-mounted view; SwiftUI does not call `makeUIView` again, so the new
        // connection can be perfectly healthy while every frame disappears into no display.
        // Keep both the attachment and the last good frame until the replacement stream's config
        // arrives. A deliberate end really removes the screen and releases the decoder.
        if deliberate { renderer.detach() }
        // Nothing is open any more, which is the widget's business as much as the card's.
        publishOpenMacs()
        // An end this app chose is not a session the relay cut. Cleared here as well as on a
        // session coming up, because this path sets the phase directly and so never passes
        // through the drop handling in ``apply(_:)-swift.enum.case`` that would clear it.
        relaySessionDropped = false
        latchedModifiers = []

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
    /// **The handover is the whole of it.** Every other per-Mac value ends with its own session,
    /// but the picture, the sound, the floating window and the Live Activity are singular and
    /// belong to whichever Mac is being looked at — so ending that Mac has to give them to the
    /// next one rather than leave them pointed at a session that has stopped. Leaving the pointer
    /// where it was is the failure that matters: the screens read through
    /// ``SessionModel/activeSession``, so they would go on drawing a Mac that is gone, and the
    /// strip would show a selection with no tab to match it.
    ///
    /// Ending a Mac that is *not* on screen needs none of that, and is the cheap case: its own
    /// state goes with it and nothing the user is looking at changes.
    func endSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }

        // Cleared before the teardown, so what follows reads as a switch *out of* a session
        // rather than a switch into one. ``activateSession(_:)`` is a no-op for the Mac already on
        // screen, and the Mac being ended is still that until this line runs.
        let wasActive = activeSessionID == id
        if wasActive { activeSessionID = nil }

        // The user asked for this one, said to the Mac it is about. `wire` announces its own end
        // and the phases above are already where they are by the time it arrives, so this record
        // is the only evidence left that the user rather than the network ended it. See
        // ``MacSession/userEndedDeliberately`` for why it is not kept on the container.
        session.endSession(deliberate: true)

        guard wasActive else {
            publishOpenMacs()
            return
        }

        if let next = openSessions.first {
            activateSession(next.id)
        } else {
            // Nothing left to hand to, so the app is back where ``disconnect(deliberate:)``
            // leaves it, for the same reason: these are one of each for the whole app, and a Mac
            // nobody is connected to must not be left owning any of them.
            renderer.detach()
            SessionAudio.shared.end()
            SessionPiP.shared.detach()
            SessionActivity.shared.sessionEnded()
            publishOpenMacs()
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
    // MARK: - Relay presence

    /// Asks the relay which of the paired Macs are up, and takes the answer as the whole truth.
    ///
    /// **An empty answer is not news**, and that distinction is the point. `hostPresence` returns
    /// nothing both when the relay answered with an error and when the network was down, and
    /// neither of those is the relay saying every Mac has gone. So a round that learned nothing
    /// leaves what was known standing, and only a round that learned *something* replaces it.
    ///
    /// Called by the Connect tab while it is on screen. Nothing polls in the background: the
    /// answer is only ever drawn there, and a phone that asked after its Macs from a pocket would
    /// be telling the relay where its owner is for no one's benefit.
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

        // Replaced rather than merged, because a Mac that has gone is *absent* from the answer:
        // merging would leave a stale `true` on the row of a Mac that is switched off.
        relayPresence = answers
    }

    /// Puts every Mac that has dropped back, and starts the one that was open last if none is.
    ///
    /// **One call, over every session and then the cold case**, because the three places this is
    /// called from are all asking the same question: coming back to the front, a Mac appearing in
    /// the browser, and the ladder's own tick. Each session resumes itself — see
    /// ``MacSession/resumeIfNeeded()`` — and what is left here is the launch where there is no
    /// session at all and the only evidence of one is what was written down before the app died.
    func resumeIfNeeded() {
        for session in sessions { session.resumeIfNeeded() }
        resumeTheLastMacIfNothingIsOpen()
    }

    /// The cold launch: nothing is open, and `resumeKey` says there was something.
    ///
    /// A separate path rather than a branch of the loop above, because a session that does not
    /// exist yet cannot know which Mac it is for: the ID is in the defaults and nowhere else. It
    /// is also the only case where Bonjour can be consulted by *name*, which is what a device
    /// that dropped before the handshake was ever recorded by.
    private func resumeTheLastMacIfNothingIsOpen() {
        // **Only the launch with nothing in it.** With a session object at all, the loop above
        // has already asked that session to put itself back, and a second dial for the same Mac
        // would race the first and close its connection mid-handshake.
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
    /// **The door the strip's `+` and the picker's rows both come through.** The gate and the
    /// ceiling are enforced one level down in ``SessionModel/connect(to:replacing:)``, because
    /// that is where every route from anywhere in the app actually arrives; this is the name the
    /// screens call and the place the "already open" question is answered.
    func addSession(hostID: String) {
        // **A Mac already open is brought to the front rather than opened twice.** Two sessions
        // to one Mac would be two control channels, two terminal lists and two meters for one
        // machine, and the Mac itself would see two clients where the user has one phone.
        if let open = sessions.first(where: { $0.hostID == hostID && $0.isLive }) {
            activateSession(open.id)
            return
        }
        connect(to: relayTarget(hostID: hostID, name: displayName(forHostID: hostID) ?? "A Mac"))
    }

    /// The paired Macs that are not already open, which is what the strip's `+` offers.
    ///
    /// Most recently connected first, for the same reason the widget's list is: the Mac someone
    /// wants to add is almost always one they have used lately.
    var closedPairedMacs: [(id: String, name: String)] {
        let open = Set(sessions.compactMap(\.hostID))
        return pairedHostIDs
            .filter { !open.contains($0) }
            .sorted { (lastConnectedAt[$0] ?? .distantPast) > (lastConnectedAt[$1] ?? .distantPast) }
            .map { (id: $0, name: displayName(forHostID: $0) ?? "A Mac") }
    }

    /// Replaces one Mac's session with a fresh attempt at the same Mac, and leaves the rest alone.
    ///
    /// **The old session is removed rather than left to be pruned**, because it is the one being
    /// replaced and its ladder has just handed over: leaving it would put two entries for one Mac
    /// in the strip for as long as the new attempt takes, which is exactly the state the user
    /// would read as "it connected twice".
    func reconnect(_ session: MacSession, to target: ClientSession.Target) {
        connect(to: target, replacing: session)
    }

    /// Stops the active Mac being retried, *without* resetting its backoff.
    ///
    /// The counter belongs to a run of attempts, and resetting it here is what turned a failing
    /// reconnect into a permanent loop: every cycle called this, so the attempt count returned to
    /// zero and the delays never advanced past the first second. Only a session that actually
    /// came up clears it — see the `.ready` branch in ``MacSession/apply(_:)``.
    func stopReconnecting() { activeSession?.stopReconnecting() }

    // MARK: - Backgrounding

    /// Tells the object that floats the picture whether the plan includes it, and answers the
    /// same question for the caller.
    ///
    /// **One writer, called wherever the answer can change**: when the App Store's entitlement
    /// first lands, whenever it changes under a running app, and as the app leaves the screen.
    /// See ``SessionPiP/isOnPlan`` for why that value is pushed into the singleton rather than
    /// read inside it.
    ///
    /// It exists as a function rather than as a line at each of those sites because the three of
    /// them are the same question, and the one that is easy to leave out is the launch: a
    /// subscriber whose controller was armed before the App Store answered would be armed with
    /// the wrong answer for the rest of the session.
    @discardableResult
    func applyPictureInPicturePlan() -> Bool {
        let included = PictureInPictureAccess.canArm(access: storeManager.access)
        SessionPiP.shared.isOnPlan = included
        return included
    }

    /// Tells the object that raises terminal banners whether the plan includes them, and answers
    /// the same question for the caller.
    ///
    /// **Its twin, and called from the same moments**: the other half of the same feature is the
    /// registration refused in ``sendPushToken()``, which reads the plan directly because it has
    /// the store in front of it. This one is a push rather than a read because the object it
    /// informs has no store, which is the same arrangement ``SessionPiP`` is kept in.
    ///
    /// The banner it gates has no tap to wait for: a shell stops and the banner is raised, and the
    /// only question the app can ask is whether the answer was already known. Failing closed until
    /// it is costs a subscriber one banner in the first moments of a launch.
    @discardableResult
    func applyTerminalAlertPlan() -> Bool {
        let included = TerminalAlertsAccess.canNotify(access: storeManager.access)
        SessionNotifier.shared.isOnPlan = included
        return included
    }

    var isPiPSupported: Bool { SessionPiP.isSupported }
    var pipLastAttempt: String? { SessionPiP.shared.lastAttempt }
    var pipLastRefusal: String? { SessionPiP.shared.lastRefusal }

    func startPiP() { SessionPiP.shared.start() }
    func setPiPAutoStart(_ on: Bool) { SessionPiP.shared.autoStart = on }

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

        // **The plan, pushed into the singleton before it is asked to float anything.** PiP is on
        // the Relay plan and above, and the picture is drawn by an object that owns no store, so
        // this is where the app tells that object what it is allowed to arm. Written on every
        // backgrounding rather than once, because an entitlement can arrive or lapse while the
        // app runs, and a stale answer here is either a locked feature starting anyway or a paid
        // one refusing to.
        //
        // The switch's own preference is not pushed from here. It belongs to ``SessionPiP``,
        // which reads it from the defaults and has it written by the two toggles that draw it,
        // and a third copy would be a third place for it to disagree.
        let pipIncluded = applyPictureInPicturePlan()

        // And the other thing that is allowed to arrive on its own: a shell that stops while the
        // app is not on screen raises its banner rather than waiting for a tap, so the answer it
        // reads has to be the current one.
        applyTerminalAlertPlan()

        // Started here rather than left to `canStartPictureInPictureAutomaticallyFromInline`.
        // That flag is set, and the picture does float when it is started by hand — but iOS
        // never takes the hint. Automatic PiP is gated on the system considering the app to be
        // *playing*, and an `AVAudioPlayer` running silence is not something it counts, however
        // active the session is.
        //
        // Asking at the one moment it is wanted costs nothing and does not depend on that
        // judgement — and the moment matters: this runs as the app leaves the screen, which is
        // when `startPictureInPicture` still has a view hierarchy to lift the layer out of.
        //
        // `false` for a plan without it, which reads in ``SessionPiP`` as "no session up" and is
        // the honest answer to the question it is really asking: there is nothing here to float.
        SessionPiP.shared.backgrounding(sessionIsUp: phase.holdsSession && pipIncluded)

        // Also keep the process alive when the reconnect ladder is running. A LAN session that
        // drops moves to `.failed` immediately — before `enteringBackground()` — so
        // `phase.holdsSession` is already false. Without this, the app suspends, `Task.sleep`
        // freezes, and the "dropped" Live Activity card is never shown.
        // Held for as long as **any** Mac is open or being retried. What iOS suspends is the
        // process, so the assertion is about the app rather than about the Mac on screen, and a
        // session behind the active one would otherwise be killed with no chance to say so.
        guard hasOpenSession, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Peering session") { [weak self] in
            Task { @MainActor in self?.backgroundTimeExpired() }
        }
    }

    func enteringForeground() {
        SessionActivity.shared.returningToForeground()
        endBackgroundAssertion()

        // **The App Store's answer, re-read before anything is armed from it again.** A
        // subscription that ran out while this app was off screen produced no transaction to
        // notice it by, so the plan this process holds can be hours out of date — and every gate
        // reads it. Asked here rather than at the moment of a backgrounding because the reading is
        // local and this is the one point where waiting for it costs nothing: the session is being
        // resumed, not torn down. The change lands in ``StoreManager/access``, which is what the
        // two pushes above it and the plan sent to the relay all read.
        Task { await storeManager.rereadEntitlement() }
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
        let shouldEndSession = BackgroundSessionExpiry.shouldEndSession(
            assertionIsActive: backgroundTask != .invalid,
            appIsBackground: UIApplication.shared.applicationState == .background,
            hasOpenSession: hasOpenSession,
            // PiP is a system-owned background presentation. Once it is active, iOS is keeping
            // the app alive for real media playback; the temporary assertion expiring must not
            // tear down the session underneath the floating window.
            pictureInPictureIsActive: SessionPiP.shared.isActive
        )
        endBackgroundAssertion()
        // **Every Mac**, and one call because ``disconnect(deliberate:)`` already means all of
        // them. This used to end one session and then handle the ladder-running case separately:
        // with several Macs those two branches are the same branch, and the second one is the
        // case where a Mac behind the active one was left to be killed unobserved. The card and
        // the banner are taken down by the same path, which is the whole reason for ending it
        // tidily rather than letting the system do it.
        guard shouldEndSession else { return }
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
