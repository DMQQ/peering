import MacCastKit
import RemoteCore
import SwiftUI

/// An event belongs to the connection that delivered it, so it is applied to that connection's state: an event from one Mac must not move another's picture, phase or terminals. Every mutation is `self.`; only app-wide consequences (notification, Live Activity, history store, reconnect ladder) reach through ``model``.
extension MacSession {
    func apply(_ event: ClientSession.Event) {
        switch event {
        case .phase(let phase):
            CrashLog.note("phase \(phase) · \(hostID ?? "unknown")\(isReconnecting ? " (reconnecting)" : "")")
            var shouldScheduleReconnect = true
            // A failure during a resume is retried, not shown: when this Mac had reached Ready it is one step of the reconnect ladder (see ``SessionModel/isResuming``). A cold-launch restoration's first failure is terminal, shown once, and clears the persisted request.
            if case .failed = phase, model.isResuming {
                model.isResuming = false
                // The attempt is over: `resumeIfNeeded` refuses to start while a wire is held, which is true from `connect(to:)` until the attempt fails.
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
                    // Nothing will dial this Mac again, so it stops being one the app is putting back; left set, the failure would be shown under a header still saying reconnecting.
                    isComingBack = false
                }
            }
            if phase.holdsSession {
                model.isResuming = false
                // A session that is up again is a resume that arrived; without this the next drop would be the tail of the last one, with the shorter ladder already spent.
                hasGivenUpResuming = false
            }

            // Read before the assignment: what is said about a transition is about where the session came from as well as where it landed.
            let previous = self.phase
            if previous == .ready, phase != .ready {
                // Read before `finishSessionHistory()` and the teardown below, both of which take a piece of it. Only a relay session ending without the user ending it is recorded (``SessionModel/relaySessionDropped``); a LAN drop is not, since the relay cannot have cut it. Read from this Mac's own record because the flag below is cleared on the way past (``MacSession/userEndedDeliberately``).
                if !userEndedDeliberately, connectionPath == .relay {
                    model.relaySessionDropped = true
                }
                closeStretch()
                finishSessionHistory()
            }
            let cappedFailure = previous == .ready ? retryCapFailure(for: phase) : nil
            if previous == .ready, case .failed = phase { noteDropped(capped: cappedFailure != nil) }
            if cappedFailure != nil { shouldScheduleReconnect = false }
            self.phase = cappedFailure ?? phase
            if phase == .ready {
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
            if case .failed(let message) = phase {
                reportConnectFailure(appState: Analytics.name(of: UIApplication.shared.applicationState))
                videoStatus = String(localized: "Stopped: \(message)")
            }
            if phase == .disconnected {
                videoStatus = String(localized: "Disconnected")
            }
            if phase == .ready {
                // Read before the line below overwrites it: `hasBeenReady` tells a reconnect from a connection, which decides whether the record a drop filed is continued or a new one started. The value is the one the ladder carried onto this object (see ``SessionModel/connect(to:replacing:)``).
                let hadBeenReady = hasBeenReady
                hasBeenReady = true
                // Cleared so a drop followed by a working reconnect cannot label a refusal an hour later as the relay cutting something.
                model.relaySessionDropped = false
                // Restarted on every arrival: a reconnect emits `.ready` again, and elapsed time kept counting through it would describe a session that no longer exists.
                if previous != .ready {
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
            } else {
                sessionStartedAt = nil
            }

            // This Mac's own answer, kept on the record rather than cleared here: everything asking whether a session is being put back reads it a moment later, and clearing it left a Quit showing reconnecting. Every attempt is a new session object, so nothing needs it cleared. See ``MacSession/userEndedDeliberately``.
            let userEnded = userEndedDeliberately
            // A session that ended without the user asking is put back on its own; the flag inside `scheduleReconnect` decides, since the phase cannot tell a drop from a disconnect. Before the activity is told, since scheduling sets `isReconnecting` and the card must say reconnecting, and before the banner, whose question is whether the drop is already being put back.
            if !phase.holdsSession, !userEnded, shouldScheduleReconnect {
                // Released here, or the ladder cannot take a single step: `resumeIfNeeded` guards on `session == nil`, and neither `disconnect()` nor `connect(to:)` runs when a session drops on its own, so the first tick saw a session, called `stopReconnecting`, and nothing re-armed. The object is finished with: `ClientSession.fail` cancels the control connection, video socket, datagram lane and relay proxy before emitting this phase.
                connectTask?.cancel()
                connectTask = nil
                wire = nil
                scheduleReconnect()
            }

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
            }

            if !phase.holdsSession {
                // The buttons stop claiming a modifier once its link is gone, since the release cannot travel back. The window server keeps the flag until a real key-up, so the Mac may still hold it, which is why this says so.
                if !model.latchedModifiers.isEmpty {
                    append(note: String(localized: "The connection ended while \(model.latchedModifiers.label) was held on the Mac. It may still be held there."))
                }
                model.latchedModifiers = []
                privacyModeEnabled = false
            }
        case .host(let hello):
            // The host's own name is authoritative; Bonjour is only a hint and can be minutes stale.
            hostName = hello.hostName
            hostID = hello.serverID
            // Recorded once at the door rather than guessed each time. See ``PicturePause/mayAsk(hostDeclared:)``.
            hostSupportsVideoPause = PicturePause.mayAsk(hostDeclared: hello.supportsVideoPause)
            hostSupportsAgentList = hello.supportsAgentList == true
            // A chat is a request an older Mac cannot decode, so it is sent only to a Mac that said it can. See ``AgentChatSupport``.
            hostSupportsAgentChat = AgentChatSupport.maySend(toHostDeclared: hello.supportsAgentChat)
            hostSupportsClipboardImages = ClipboardImages.maySend(toHostDeclared: hello.supportsClipboardImages)
            // Compositing is the first request this client can make that an older Mac cannot decode at all. See ``MosaicSupport``.
            hostSupportsMosaic = MosaicSupport.maySend(hostDeclared: hello.supportsMosaic)
            hostSupportsSourceThumbnails = SourceThumbnailSupport.maySend(
                hostDeclared: hello.supportsSourceThumbnails
            )
            hostSupportsDeviceOrientation = DeviceOrientationSupport.maySend(
                hostDeclared: hello.supportsDeviceOrientation
            )
            hostSupportsVirtualDisplayManagement = VirtualDisplayManagementSupport.maySend(
                hostDeclared: hello.supportsVirtualDisplayManagement
            )
            hostPushesTerminalAlertsWhileConnected = hello.pushesTerminalAlertsWhileConnected == true
            hostSupportsFileBrowser = hello.supportsFileBrowser == true
            hostSupportsAgentModelPicker = hello.supportsAgentModelPicker == true
            hostSupportsAgentPermissionModes = hello.supportsAgentPermissionModes == true
            hostSupportsAgentUsage = hello.supportsAgentUsage == true
            hostSupportsAgentSessionImport = hello.supportsAgentSessionImport == true
            hostSupportsAgentPause = hello.supportsAgentPause == true
            hostChatAgents = Set(hello.agentChatAgents ?? ["claude", "codex"])
            UserDefaults.standard.set(hello.serverID, forKey: SessionModel.lastHostIDKey)
            // Also the name the widget and Lock Screen card show, as the only one that came from the Mac itself; a first pairing by ID knows no name until this arrives.
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
            // A changed catalogue may have lost a window (an app quit, a stale arrangement, a tile stopped). The reaction is not immediate: see ``scheduleMosaicGapCheck()``.
            if !mosaicChoices.isEmpty { model.scheduleMosaicGapCheck() }
            // Consumed here, the first catalogue this connection receives, before the branch below decides between a session with nothing chosen and one repeating a choice the Mac forgot. See ``pendingSourceReassertion``.
            let reasserting = pendingSourceReassertion
            pendingSourceReassertion = false
            if let requested = sourceRequestedOnOpen,
               let descriptor = catalog.all.first(where: { $0.id == requested }) {
                // A notification named this window, which outranks anything remembered.
                sourceRequestedOnOpen = nil
                model.selectSource(descriptor)
            } else if activeSourceID == nil {
                // A remembered arrangement comes back before the default: the fallback picks the first display, and a mosaic asked on top would be a second capture. Only when nothing has been chosen yet; a session already showing something keeps it, and a resumed one still has the mosaic's id as its source.
                let remembered = model.mosaicToRestore(hostID: hostID, catalog: catalog)
                if !remembered.isEmpty {
                    // Asked for, not remembered: the store holds the arrangement, thinned here by what this catalogue can see, and writing the thinned version back would lose a window the catalogue merely failed to list.
                    model.showMosaic(remembered, remembering: false)
                } else if let source = model.sourceToRestore(hostID: hostID, catalog: catalog) {
                    // After the arrangement, before the first display. Through the door rather than assigned here: a remembered source is one the Mac has to be told about, else the session would describe a picture the Mac is not sending.
                    model.selectSource(source)
                } else if let first = catalog.displays.first ?? catalog.all.first {
                    // Asked for too, though it is the Mac's fallback: the Mac waits a second for an ask, which a new pairing would otherwise always spend.
                    model.selectSource(first)
                }
            } else if reasserting {
                // A reconnect where this end knows what it wants: told again, since the fresh capture pipeline has no memory of `activeSourceID`. See ``pendingSourceReassertion``.
                // Read from `activeSourceID`, not `isAskingForMosaic`: the session object is new and only `activeSourceID` and `mosaicChoices` were carried (see ``SessionModel/connect(to:replacing:)``).
                // Matched by prefix, not by recomputing the layout hash: the `stableID` hashes the exact canvas size, which depends on window sizes a re-enumerated catalogue may report in a different order or precision, so a hash comparison never matched and the reassertion silently did nothing. The prefix is the part of the id that does not move. See ``CaptureSource/stableID``.
                if !mosaicChoices.isEmpty, activeSourceID?.hasPrefix("mosaic:") == true {
                    model.showMosaic(mosaicChoices, remembering: false)
                } else if let activeSourceID,
                          let descriptor = catalog.all.first(where: { $0.id == activeSourceID }) {
                    model.selectSource(descriptor.source)
                }
            }
        case .video(let event):
            apply(video: event)
        case .latency(let milliseconds):
            latencyMilliseconds = milliseconds
            warnIfConnectionIsVeryBad(milliseconds)
        case .pathLatency(let milliseconds, let fromPeer):
            pathLatencyMilliseconds = milliseconds
            pathLatencyIsDirect = fromPeer
        case .datagramCounts(let counts):
            datagramCounts = counts
        case .note(let message):
            append(note: message)
        case .path(let path):
            // Recorded and deliberately not shown: the session already logs a note when it changes. Not folded into ``connectionPath``: the relay meters by splice time whether or not video went around it, so moving the path off `.relay` would make ``SessionModel/relaySecondsUsedThisPeriod`` under-report sessions the relay still charges for.
            usedDirectPath = path == .direct
        case .directPath(let outcome):
            // The other half: `path` says where the picture is arriving when it works; this says what the attempt came to when it does not. Shown rather than logged because a failure has no note in the session log to find it in.
            directPathStatus = outcome
            append(note: String(localized: "Direct path: \(outcome.summary)"))
        case .remoteNotice(let message):
            remoteNotice = message
            // A locked Mac draws no frames for an application or window, so a session resumed on one would sit paused with no password in reach. Go to the lock screen as Unlock would; the detour restores the source once unlocked.
            if let displayID = message?.lockedDisplayID, isActive, unlockDetour == nil,
               model.activeSourceID != CaptureSource.display(displayID).stableID {
                model.showLockScreen(on: displayID)
            }
            // Unlocked: go back to what Unlock left, unless the user has moved on since.
            if message?.lockedDisplayID == nil, let detour = unlockDetour {
                unlockDetour = nil
                if isActive, activeSourceID == detour.lockScreen.stableID {
                    model.selectSource(detour.returnTo)
                    model.showKeyboard = false
                }
            }
        case .textFocus(let focus):
            if isActive { model.textFocusChanged(focus) }
        case .pointer(let point):
            if isActive { model.hostPointer = HostPointer(point: point, serial: model.hostPointer.serial + 1) }
        case .fieldState(let state):
            if isActive { model.fieldStateChanged(state) }
        case .clipboard(let payload):
            hostClipboard = payload
            clipboardPulling = false
            // Text pulls are filed; pictures are not, deliberately: the history lives in `UserDefaults` and is read at launch, so twelve screenshots would be a hundred megabytes of PNG in a plist. A picture history needs a file store with its own eviction.
            if let text = payload.text { model.rememberClipboard(text) }
        case .audio(let event):
            switch event {
            case .config(let config):
                audioPlayer = RemoteAudioPlayer(config: config)
                // A fresh player per stream, so the preference, plan and whether this is the Mac on screen are handed to each. See ``shouldPlayAudio``: a free user's audio and a background Mac's audio are still sent, and this stops them playing.
                refreshAudioMuteState()
            case .frame(let frame):
                audioPlayer?.enqueue(frame)
            }
        case .terminal(let event):
            apply(terminal: event)
        case .agent(let event):
            apply(agent: event)
        case .hostStopped:
            // Arrives just before the failure it explains, so that failure ends the session instead of arming the ladder against a Mac that is no longer listening.
            userEndedDeliberately = true
            stopReconnecting()
        case .relayQuotaExceeded:
            // Through ``StoreManager/access``, the answer every other screen states: `relayPlan` is what the device tells the relay and is free with no receipt (a developer override, or before StoreKit answers), so read for copy it contradicted every badge.
            let plan = model.storeManager.access.plan
            if plan?.isUnlimited != false {
                // A plan the relay does not meter was refused, so the relay read this device as free (an older relay or an unknown plan). Nothing to do here and a retry against an updated relay may succeed, so it stays a note rather than a paywall in front of someone who has paid.
                append(note: String(localized: "Relay quota reached. Your subscription is active; please try again later."))
            } else if model.relaySessionDropped {
                // The mid-session cut: the relay ends a session the moment its allowance is spent by dropping the connection, with no way to say why (everything past the token is TLS). This sheet says it, opening on the plans. Not the paywall itself, whose question is which plan is worth it; being sold to while being told is how a wall turns into a con.
                model.spentAllowance = plan ?? .free
                Analytics.relayAllowanceExhausted(path: connectionPath?.rawValue)
                model.relaySessionDropped = false
                // The cut is simultaneous: the relay reads one counter per client, so every spliced session is dropped at once. Ending only the Mac that noticed leaves dead tabs behind the sheet.
                // The flag is cleared above so the ends this causes cannot re-enter this branch.
                // Nothing is recorded here about who ended it: `disconnect(deliberate: false)` assigns that flag from its own argument, so an earlier write was overwritten before it could be read. The ladder arming after a cut is long-standing: the next attempt is refused for the same reason and answered by the branch below.
                model.disconnect(deliberate: false, endReason: .quota)
            } else if model.spentAllowance != nil {
                // A later refusal from the same ladder has nothing to add: the explanation is on screen and the purchase screen must not cover it. The ladder re-arms on a failed attempt by design, so this is the second and third refusal of the same cut.
                userEndedDeliberately = true
                model.stopReconnecting()
            } else if hasBeenReady {
                // An automatic retry of a session that was working: explained by the sheet and never sold at, since the user did not walk into this.
                model.spentAllowance = plan ?? .free
                Analytics.relayAllowanceExhausted(path: connectionPath?.rawValue)
                reportEnd(.quota)
                userEndedDeliberately = true
                model.stopReconnecting()
            } else {
                // Free with the day's allowance spent and the user tapped Connect into it: a wall they walked into, not a session taken away, which is why this branch is the paywall.
                model.paywallReason = .quotaExhausted
                Analytics.relayAllowanceExhausted(path: nil)
                // Suppress the reconnect ladder: there is nothing to reconnect to.
                userEndedDeliberately = true
                model.stopReconnecting()
            }
        }
    }

    func apply(video event: ClientSession.VideoEvent) {
        switch event {
        case .connecting:
            videoStatus = String(localized: "Opening the video channel…")
            isVideoStreaming = false
        case .config(let config):
            // The decoder half is done on the network queue where frames are handled, so it is ordered against them (see the event handler in `connect(to:)`): doing it here would reset after a keyframe from the same read and throw it away. Only the labels belong on the main actor.
            videoStatus = "\(config.codec.rawValue.uppercased()) \(config.pixelWidth)×\(config.pixelHeight)"
            isVideoStreaming = true
            // A picture has been sent to this attempt, which allows the relay handover; sticky because a config is. See ``MacSession/hasHadPicture``.
            hasHadPicture = true
            // Published, not acted on: the zoom and pan that answer to it live in the screen, and ``PictureIdentity`` is all it needs. A config describing the stream it already described leaves it equal.
            picture = pictureIdentity(of: config)
            // The renderer gets the source identity atomically with the config on its serial queue; setting it here raced the first frame.
            // Record the arrangement the picture is of here, because a config is the Mac answering the ask and the moment picture and this end's idea of it agree again. Not animated: borders travelling over a picture that has already changed read as rectangles shuffling on their own.
            // Recorded only when the config's canvas matches the ask as it was made (``MacSession/askedMosaicLayout``), not the one this end would build now: ``mosaicLayout`` is rebuilt from the live screen and catalogue, so recording it stored arrangements the Mac never built and overlays were mapped through a canvas that was not on screen. A picture that does not match leaves the record alone.
            if let asked = askedMosaicLayout,
               CaptureSource.mosaic(asked).stableID == config.sourceID {
                pictureMosaicLayout = asked
            } else if !config.sourceID.hasPrefix("mosaic:") {
                pictureMosaicLayout = nil
            }
            // Anything else leaves the record alone: the picture is still the last arrangement that answered, until the Mac catches up.
            append(note: "Video stream started: \(config.pixelWidth)×\(config.pixelHeight) \(config.codec.rawValue.uppercased())")
        case .frame:
            break // Handled on the network queue; see `connect(to:)`.
        case .transport(let transport):
            // The client's own decision, reported back: the picture looks the same on either lane but smaller on one, so without this the user guesses why the Mac looks soft.
            videoTransport = transport
            if transport == .control {
                append(note: String(localized: "The picture is coming over the control channel, at reduced quality."))
            } else {
                append(note: String(localized: "The picture is back on the direct video channel."))
            }
        case .ended(let reason):
            videoStatus = String(localized: "Video ended: \(reason)")
            isVideoStreaming = false
        }
    }

    func startVideoPolling() {
        videoPoll?.cancel()
        videoPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                // The one tick that outlives a dial: a dial that never answers ends nothing, and this stops the screen saying Reconnecting while the network is silent. See ``SessionModel/reconnectWindow``.
                giveUpAfterReconnectWindow()
                let snapshot = self.renderer.currentSnapshot
                if snapshot.hasConfig {
                    self.captureSessionBandwidth(snapshot)
                    self.updateFrameRate(from: snapshot)
                    self.updateAutoQuality(from: snapshot)
                    self.measureResumeIfNeeded(snapshot)

                    let suffix = snapshot.framesDropped > 0 ? String(localized: " · \(snapshot.framesDropped) dropped") : ""
                    let waiting = snapshot.awaitingKeyframe ? String(localized: " · waiting for a keyframe") : ""
                    // Said here, not only in the notes: a reduced rate nothing on screen explains reads as a fault.
                    let lane = self.videoTransport == .control ? String(localized: " · sharing the control channel") : ""
                    // The rate leads: the question a choppy picture raises is frames per second, which only a difference between two samples answers.
                    let rate = self.videoFramesPerSecond > 0
                        ? String(localized: " · \(Int(self.videoFramesPerSecond.rounded())) fps")
                        : ""
                    self.videoStatus = "\(snapshot.codec.rawValue.uppercased()) \(snapshot.pixelWidth)×\(snapshot.pixelHeight)\(rate) · \(snapshot.framesEnqueued) frames\(suffix)\(waiting)\(lane)"
                }
            }
        }
    }

    /// Derived from two polls since neither end knows the other's rate. Smoothed heavily: a half-second window reads one late batch as a swing, and this is for telling thirty from sixty.
    func updateFrameRate(from snapshot: VideoRenderer.Snapshot) {
        let now = Date()
        defer { lastFrameSample = (snapshot.framesEnqueued, now) }

        guard let last = lastFrameSample else { return }
        // A count that went backwards is a reset, not a negative rate: the renderer drops its totals when the stream restarts.
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
