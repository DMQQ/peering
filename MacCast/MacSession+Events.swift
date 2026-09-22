import MacCastKit
import RemoteCore
import SwiftUI

/// What arrives from one Mac, turned into state.
///
/// **The whole reason this file is on the session and not on the model.** An event belongs to
/// the connection that delivered it, so it has to be applied to that connection's state — and
/// once there can be more than one connection, an event from the Mac on the right of the strip
/// must not move the picture, the phase or the terminal list of the Mac on the left. Every
/// mutation below is therefore `self.`, and only the genuinely app-wide consequences (the
/// notification, the Live Activity, the history store, the reconnect ladder) reach through
/// ``model``.
extension MacSession {
    func apply(_ event: ClientSession.Event) {
        switch event {
        case .phase(let phase):
            var shouldScheduleReconnect = true
            // A failure during a resume is retried, not shown. See ``SessionModel/isResuming``:
            // when this Mac had already reached Ready, this is one step of the reconnect ladder
            // and the phase is deliberately not taken. A cold-launch restoration is different:
            // its first failure is terminal, is shown once, and clears the persisted request so
            // lifecycle and browser callbacks cannot open the connecting card again.
            if case .failed = phase, model.isResuming {
                model.isResuming = false
                // **The attempt is over, so it stops counting as one in flight.**
                // `resumeIfNeeded` refuses to start while a wire is held, on the reasoning that
                // a session object means an attempt is already underway, true from the moment
                // `connect(to:)` assigns it, and false from the moment the attempt fails, which
                // is the state this branch exists in.
                connectTask?.cancel()
                connectTask = nil
                wire = nil
                switch SessionResume.failureAction(hasBeenReady: hasBeenReady) {
                case .retrySilently:
                    scheduleReconnect()
                    return
                case .stopAndShowFailure:
                    UserDefaults.standard.set(false, forKey: SessionModel.resumeKey)
                    shouldScheduleReconnect = false
                }
            }
            if phase.holdsSession {
                model.isResuming = false
                // A session that is up again is a resume that arrived, so this Mac is a Mac we are
                // connected to rather than one whose ladder has run out. Without this the next drop
                // would be the tail of the last one, and the shorter ladder would already be spent.
                hasGivenUpResuming = false
            }

            // Read before the assignment. Everything said about a transition — the banner,
            // the point the stopwatch starts from — is about where the session came from,
            // not only about where it landed.
            let previous = self.phase
            if previous == .ready, phase != .ready {
                // Read before `finishSessionHistory()` and before the teardown below, both of
                // which take a piece of it: the live session out of the meter, and the path out of
                // `connectionPath`. What is recorded is only that a session on the relay ended
                // without the user ending it. See ``SessionModel/relaySessionDropped``.
                //
                // A drop over the LAN is deliberately not recorded: the relay is not metering a
                // local session and cannot have cut one, so a refusal that followed would be the
                // other situation entirely.
                // Read from this Mac's own record rather than the container's: the flag below is
                // cleared on the way past, so the third Mac in a loop would have read the second
                // one's answer. See ``MacSession/userEndedDeliberately``.
                if !userEndedDeliberately, connectionPath == .relay {
                    model.relaySessionDropped = true
                }
                finishSessionHistory()
            }
            self.phase = phase
            if phase == .ready {
                model.pairedHostIDs = model.pins.hostIDs
                // A handshake that reached `.ready` has just established or confirmed a pin, and
                // that is one of the few moments the paired list can have changed.
                model.publishKnownMacs()
                // And the same moment is when this Mac's own ID becomes known at all, which is
                // what the widget's list is keyed by. See ``SessionModel/publishOpenMacs()``.
                model.publishOpenMacs()
                applyInitialQuality()
                wire?.sendTerminal(.list)
                // Through the model rather than the token directly: this is the moment the Mac
                // learns where to reach this device, and whether it may is the plan's answer,
                // which the model owns. See ``SessionModel/sendPushToken()``.
                model.sendPushToken()
            }
            if case .failed(let message) = phase {
                videoStatus = "Stopped: \(message)"
            }
            if phase == .disconnected {
                videoStatus = "Disconnected"
            }
            if phase == .ready {
                hasBeenReady = true
                // A session that came up is not a session that was cut, whatever the last one
                // did. Cleared here so a drop that was followed by a working reconnect cannot
                // label a refusal an hour later as the relay having cut something.
                model.relaySessionDropped = false
                // Restarted on every fresh arrival rather than only the first: a reconnect
                // emits `.ready` again, and elapsed time that kept counting through it would
                // be describing a session that no longer exists.
                if previous != .ready {
                    model.reconnectAttempt = 0
                    sessionStartedAt = Date()
                    beginSessionHistory()
                    UserDefaults.standard.set(true, forKey: SessionModel.resumeKey)
                    // Record the last-connected timestamp for the Trusted Macs list.
                    if let id = hostID {
                        model.lastConnectedAt[id] = Date()
                        if let data = try? JSONEncoder().encode(model.lastConnectedAt) {
                            UserDefaults.standard.set(data, forKey: "hostLastConnectedAt")
                        }
                    }
                }
            } else {
                sessionStartedAt = nil
            }

            // **This Mac's own answer, cleared as it is read.** One flag served every Mac, and
            // ending several at once meant the first transition consumed it: the rest were read as
            // having dropped and armed a ladder that could never complete. See
            // ``MacSession/userEndedDeliberately``.
            let userEnded = userEndedDeliberately
            userEndedDeliberately = false
            // A session that ended without the user asking is put back on its own. The flag
            // inside `scheduleReconnect` is what decides whether this was theirs; the phase alone
            // cannot tell a drop from a disconnect.
            //
            // Before the activity is told, not after: scheduling is what sets `isReconnecting`,
            // and the card has to go up saying "reconnecting" rather than be taken down and
            // brought back a moment later as though nothing had happened.
            //
            // **Before the banner too, and for a reason of its own.** The banner's question is
            // whether this drop is already being put back, and the whole of that answer is
            // `isReconnecting`, which is false until this block has run. Posted first, every
            // network switch would announce itself in the most visible place it has, which is
            // exactly the thing being fixed here.
            if !phase.holdsSession, !userEnded, shouldScheduleReconnect {
                // **Released here, or the ladder cannot take a single step.**
                //
                // `resumeIfNeeded` opens with `guard session == nil, !phase.holdsSession`, and the
                // first half of that is the record of an attempt being in flight. Only
                // `disconnect()` and `connect(to:)` used to clear it, and neither runs when a
                // session drops on its own: the phase went to `.failed` with the dead session
                // still held here. The ladder armed itself, its first tick called `resumeIfNeeded`,
                // the guard saw a session and called `stopReconnecting`, and nothing ever re-armed
                // it. The five attempts the app documents never happened once, which is the
                // opposite of what the failure card said at the time.
                //
                // The object is finished with by now. `ClientSession.fail` cancels the control
                // connection, the video socket, the datagram lane and the relay proxy before it
                // emits this phase, so what is being let go of here is a reference to something
                // that has already let go of everything else.
                connectTask?.cancel()
                connectTask = nil
                wire = nil
                scheduleReconnect()
            }

            // **Every Mac, unlike the card.** A banner is about a Mac the user is not looking at
            // by definition, and a background Mac dropping is exactly the thing holding the
            // connection open was supposed to spare them. Keyed by host, so two Macs' banners
            // queue rather than replace each other. See ``SessionAwareness/Notification/hostID``.
            //
            // The same transition, said twice: once as something that can interrupt the user from
            // another app, and once as something they will see without unlocking. Neither is a
            // substitute for the other, and both read from this one place.
            model.notifier.sessionMoved(
                from: previous,
                to: phase,
                hostName: hostName ?? "the Mac",
                hostID: hostID,
                deliberate: userEnded,
                resuming: isResumingAfterDrop
            )
            // Held open for as long as there is a session, so the socket outlives the app being
            // on screen. Start before the card rather than after: the card is worth nothing if
            // the session it describes has already been suspended. See ``SessionAudio``.
            if phase.holdsSession {
                SessionAudio.shared.begin()
            } else {
                SessionAudio.shared.end()
            }

            // **The card describes the Mac on screen and no other.** There is one Activity and
            // one handle for the whole app, so a Mac behind the active one reporting its own
            // transition would take the card away from the Mac the user is looking at — its name,
            // its clock, its path — and a background Mac dropping would replace a working session
            // on the Lock Screen with the news that something the user cannot see has failed.
            // That news is a banner's job, and it has one. See ``SessionNotifier``.
            if isActive {
                SessionActivity.shared.sessionMoved(
                    from: previous,
                    to: phase,
                    hostName: hostName ?? "the Mac",
                    startedAt: sessionStartedAt,
                    reconnecting: isReconnecting,
                    deliberate: userEnded,
                    path: Self.activityPath(connectionPath)
                )
            }

            if !phase.holdsSession {
                // The buttons stop claiming a modifier the moment the link that carried it is
                // gone. Nothing else can: the release would have to travel back over the same
                // connection. Observed on this Mac, the window server keeps the flag until a
                // real key-up arrives, so the Mac may still be holding it — which is why this
                // says so rather than quietly showing the buttons as released.
                if !model.latchedModifiers.isEmpty {
                    append(note: "The connection ended while \(model.latchedModifiers.label) was held on the Mac. It may still be held there.")
                }
                model.latchedModifiers = []
                privacyModeEnabled = false
            }
        case .host(let hello):
            // The host's own name is authoritative. Bonjour is only a hint about where to
            // find it, and it can be stale by minutes.
            hostName = hello.hostName
            hostID = hello.serverID
            // What this Mac can be asked for, recorded once at the door rather than guessed at
            // each time a picture needs stopping. See ``PicturePause/mayAsk(hostDeclared:)``.
            hostSupportsVideoPause = PicturePause.mayAsk(hostDeclared: hello.supportsVideoPause)
            // The same shape for the clipboard, and the same three states on the flag. See
            // ``ClipboardImages``, which both ends read.
            hostSupportsClipboardImages = ClipboardImages.maySend(toHostDeclared: hello.supportsClipboardImages)
            UserDefaults.standard.set(hello.serverID, forKey: SessionModel.lastHostIDKey)
            // Also the name the widget and the Lock Screen card show for the last Mac, for
            // the same reason: it is the only one of the two that came from the Mac itself.
            // It matters most where there was nothing to go on before the handshake — a
            // first pairing dialled by an ID knows no name at all until this arrives, and
            // the placeholder it was carrying would otherwise outlive the session.
            UserDefaults.standard.set(hello.hostName, forKey: SessionModel.lastHostNameKey)
            SharedStore.lastHostName = hello.hostName
            if model.hostNames[hello.serverID] != hello.hostName {
                model.hostNames[hello.serverID] = hello.hostName
                UserDefaults.standard.set(model.hostNames, forKey: SessionModel.hostNamesKey)
                model.publishKnownMacs()
            }
            if let macs = hello.macAddresses, !macs.isEmpty {
                model.hostMACAddresses[hello.serverID] = macs
                if let data = try? JSONEncoder().encode(model.hostMACAddresses) {
                    UserDefaults.standard.set(data, forKey: "hostMACAddresses")
                }
            }
        case .catalog(let catalog):
            self.catalog = catalog
            if activeSourceID == nil, let first = catalog.displays.first ?? catalog.all.first {
                activeSourceID = first.id
            }
        case .video(let event):
            apply(video: event)
        case .latency(let milliseconds):
            latencyMilliseconds = milliseconds
        case .pathLatency(let milliseconds, let fromPeer):
            pathLatencyMilliseconds = milliseconds
            pathLatencyIsDirect = fromPeer
        case .datagramCounts(let counts):
            datagramCounts = counts
        case .note(let message):
            append(note: message)
        case .path(let path):
            // Which way the picture is actually arriving, which is the one thing about a session
            // this app can only learn from the session itself.
            //
            // Recorded and deliberately not shown. The session already emits a note in words at the
            // moment it changes, and that note goes into the session's own log — see
            // ``append(note:)`` — so the fact is kept where somebody diagnosing a slow session would
            // look for it, rather than added to the screen as a standing caption about the plumbing.
            //
            // It is *not* folded into ``connectionPath``, and that is a decision rather than an
            // omission: the relay meters by how long it splices a session, whether or not the video
            // went around it, so a session that punched successfully still spends its allowance.
            // Moving the connection path off `.relay` here would make
            // ``SessionModel/relaySecondsUsedThisPeriod`` stop counting a session the relay is
            // still charging for, and the meter would under-report by exactly the sessions that
            // used the app most.
            usedDirectPath = path == .direct
        case .directPath(let outcome):
            // The other half of the same fact, and the half that was missing. `path` above says
            // where the picture *is* arriving, which is only ever answered when it works; this
            // says what the attempt came to when it does not, which is the sentence somebody
            // diagnosing a slow session actually needs. Shown rather than logged, because unlike
            // the success case there is no note in the session's own log to find it in.
            directPathStatus = outcome
            append(note: "Direct path: \(outcome.summary)")
        case .remoteNotice(let message):
            remoteNotice = message
        case .clipboard(let payload):
            hostClipboard = payload
            clipboardPulling = false
            // Every pull of *text* is filed, so the next one does not overwrite the last one
            // anywhere but on the phone's own pasteboard.
            //
            // **Pictures are not filed, and that is a decision rather than an omission.** The
            // history is written to `UserDefaults` and read back at launch, so an entry costs its
            // own size in the app's stored state for as long as it is kept: twelve screenshots
            // would be a hundred megabytes of PNG in a plist, which is both a launch cost and the
            // kind of thing a phone runs out of room for. What a picture history would need is a
            // file store and its own eviction, which is a feature rather than a line here.
            if let text = payload.text { model.rememberClipboard(text) }
        case .audio(let event):
            switch event {
            case .config(let config):
                audioPlayer = RemoteAudioPlayer(config: config)
                // A fresh player per stream, so the preference has to be handed to each one, the
                // plan with it, and the question of whether this is the Mac on screen. See
                // ``shouldPlayAudio``: a free user's audio is still sent and a background Mac's
                // audio is still sent, and this is the line that stops either being played.
                refreshAudioMuteState()
            case .frame(let frame):
                audioPlayer?.enqueue(frame)
            }
        case .terminal(let event):
            apply(terminal: event)
        case .relayQuotaExceeded:
            if model.storeManager.relayPlan.isUnlimited {
                // A plan the relay does not meter was refused, which means the relay read this
                // device as free — an older relay that does not know the plan field, or a plan it
                // does not recognise. Nothing this side can do about it, and the connection may
                // well succeed on a retry against a relay that has been updated, so it stays a
                // note rather than a paywall in front of somebody who has already paid.
                append(note: "Relay quota reached. Your subscription is active; please try again later.")
            } else if model.relaySessionDropped {
                // **The mid-session cut, which the user has had no explanation for until now.**
                // The relay ends a session the moment its allowance is spent, and it ends it by
                // dropping the connection: there is nowhere to tell the two ends why, because
                // everything past the token is a TLS session the relay cannot write into. So what
                // the user saw was their Mac vanish, then a reconnect that failed, and nothing at
                // all about money. This is the sheet that says it, and it opens on the plans.
                //
                // Not the paywall itself, which is the other door and the wrong one here: that
                // screen's question is "which of these is worth it", and the only question this
                // moment raises is "what just happened to the session I was using". Being sold to
                // in the same breath as being told is how a wall turns into a con.
                model.spentAllowance = model.storeManager.relayPlan
                model.relaySessionDropped = false
                // **The cut is simultaneous, so the answer to it is too.** The relay reads the
                // allowance live off one counter per client, so every session it is splicing sees
                // zero within the same charge period and every one of them is being dropped at
                // this moment. Ending only the Mac that happened to notice leaves the user with
                // dead tabs behind the sheet, each one failing its own way a second later.
                //
                // The flag is cleared above rather than after, so the ends this causes cannot
                // re-enter this branch and end everything a second time.
                //
                // **Nothing is recorded here about who ended it**, and there used to be a line that
                // looked like it did. It set the container's flag immediately before calling
                // `disconnect(deliberate: false)`, which assigns that same flag from its own
                // argument, so the write was overwritten before it could be read. The ladder arming
                // after a cut is the behaviour this path has always had: the next attempt is refused
                // for the same reason and is answered by the branch below.
                model.disconnect(deliberate: false)
            } else if model.spentAllowance != nil {
                // **A later refusal from the same ladder, and it has nothing to add.** The
                // explanation is already on screen, and the one thing this must not do is put the
                // purchase screen over it, the user has just been told why their session ended,
                // and a sale arriving on top of that is the app talking over itself. The ladder
                // re-arms on a failed attempt by design, so this is the second and third refusal of
                // the same cut rather than a new one.
                userEndedDeliberately = true
                model.stopReconnecting()
            } else {
                // Free with the day's allowance spent, and the user tapped Connect
                // into it. A wall they walked into rather than one that took a session away, which
                // is the whole of why this branch is the paywall and the one above is not.
                model.paywallReason = .quotaExhausted
                // Suppress the reconnect ladder: there is nothing to reconnect to.
                userEndedDeliberately = true
                model.stopReconnecting()
            }
        }
    }

    /// The picture half of the same stream of events.
    func apply(video event: ClientSession.VideoEvent) {
        switch event {
        case .connecting:
            videoStatus = "Opening the video channel…"
            isVideoStreaming = false
        case .config(let config):
            // The decoder half of this is done on the network queue, in the same place the
            // frames are handled, so that it is ordered against them — see the event handler
            // in `connect(to:)`. Flushing and reconfiguring here instead would put the reset
            // *after* a keyframe that arrived in the same read, and throw that keyframe away.
            // Only the labels belong on the main actor.
            videoStatus = "\(config.codec.rawValue.uppercased()) \(config.pixelWidth)×\(config.pixelHeight)"
            isVideoStreaming = true
            // The one place the picture on screen can turn out to be a different picture. This is
            // published rather than acted on: the zoom and the pan that have to answer to it live
            // in the screen, and ``PictureIdentity`` is the whole of what the screen needs to
            // decide. It is a value, so a config that describes the stream it already described
            // (a change of lane, a re-attach) leaves it equal and costs nothing.
            picture = pictureIdentity(of: config)
            append(note: "Video stream started: \(config.pixelWidth)×\(config.pixelHeight) \(config.codec.rawValue.uppercased())")
        case .frame:
            break // Handled on the network queue; see `connect(to:)`.
        case .transport(let transport):
            // The client's own decision, reported back to the screen. The picture looks the
            // same on either lane and is smaller on one of them, so without this the user is
            // left to guess why the Mac suddenly looks soft.
            videoTransport = transport
            if transport == .control {
                append(note: "The picture is coming over the control channel, at reduced quality.")
            } else {
                append(note: "The picture is back on the direct video channel.")
            }
        case .ended(let reason):
            videoStatus = "Video ended: \(reason)"
            isVideoStreaming = false
        }
    }

    func startVideoPolling() {
        videoPoll?.cancel()
        videoPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let snapshot = self.renderer.currentSnapshot
                if snapshot.hasConfig {
                    self.captureSessionBandwidth(snapshot)
                    self.updateFrameRate(from: snapshot)
                    self.updateAutoQuality(from: snapshot)
                    self.measureResumeIfNeeded(snapshot)

                    let suffix = snapshot.framesDropped > 0 ? " · \(snapshot.framesDropped) dropped" : ""
                    let waiting = snapshot.awaitingKeyframe ? " · waiting for a keyframe" : ""
                    // Said here rather than only in the notes, because this is the line the
                    // user reads when the picture looks wrong. A reduced rate that nothing on
                    // screen explains reads as a fault in the app.
                    let lane = self.videoTransport == .control ? " · sharing the control channel" : ""
                    // The *rate* leads, and the running total follows it. "1234 frames" answers
                    // how long the session has been up; the question a picture that looks choppy
                    // actually raises is how many are arriving each second, and only a
                    // difference between two samples can answer it.
                    let rate = self.videoFramesPerSecond > 0
                        ? " · \(Int(self.videoFramesPerSecond.rounded())) fps"
                        : ""
                    self.videoStatus = "\(snapshot.codec.rawValue.uppercased()) \(snapshot.pixelWidth)×\(snapshot.pixelHeight)\(rate) · \(snapshot.framesEnqueued) frames\(suffix)\(waiting)\(lane)"
                }
            }
        }
    }

    /// Frames per second as they are actually arriving, smoothed.
    ///
    /// Derived from the difference between two polls rather than reported by anyone: neither end
    /// knows the rate at which the other is running, and the only place the two meet is here.
    /// Smoothed heavily because a half-second window is short enough that a single late batch
    /// reads as a swing, and what this is for is telling thirty apart from sixty.
    func updateFrameRate(from snapshot: VideoRenderer.Snapshot) {
        let now = Date()
        defer { lastFrameSample = (snapshot.framesEnqueued, now) }

        guard let last = lastFrameSample else { return }
        // A count that has gone backwards is a reset, not a negative rate — the renderer drops
        // its totals when the stream restarts.
        guard snapshot.framesEnqueued >= last.count else {
            videoFramesPerSecond = 0
            return
        }
        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed > 0 else { return }

        let rate = Double(snapshot.framesEnqueued - last.count) / elapsed
        videoFramesPerSecond = videoFramesPerSecond == 0
            ? rate
            : videoFramesPerSecond * 0.6 + rate * 0.4
    }
}
