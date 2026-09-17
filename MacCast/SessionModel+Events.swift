import RemoteCore
import SwiftUI

/// What arrives from the session, turned into state.
///
/// An extension on the model rather than a type of its own: this state is the
/// model's, and splitting the *type* would mean either exposing it or copying it.
extension SessionModel {
    func apply(_ event: ClientSession.Event) {
        switch event {
        case .phase(let phase):
            // A failure during a resume is retried, not shown. See ``isResuming``: this is a
            // race with the teardown of the session that just ended, it clears itself in under
            // a second, and `.failed` is what puts an alert on screen — so the phase is
            // deliberately not taken. Cleared here rather than in the ladder so the ladder's
            // own terminal failure, if it comes to one, is allowed through.
            if case .failed = phase, isResuming {
                isResuming = false
                scheduleReconnect()
                return
            }
            if phase.holdsSession { isResuming = false }

            // Read before the assignment. Everything said about a transition — the banner,
            // the point the stopwatch starts from — is about where the session came from,
            // not only about where it landed.
            let previous = self.phase
            self.phase = phase
            if phase == .ready {
                pairedHostIDs = pins.hostIDs
                // A handshake that reached `.ready` has just established or confirmed a pin, and
                // that is one of the few moments the paired list can have changed.
                publishKnownMacs()
                applyInitialAutoQualityIfNeeded()
                session?.sendTerminal(.list)
            }
            if case .failed(let message) = phase {
                videoStatus = "Stopped: \(message)"
            }
            if phase == .disconnected {
                videoStatus = "Disconnected"
            }
            if phase == .ready {
                // Restarted on every fresh arrival rather than only the first: a reconnect
                // emits `.ready` again, and elapsed time that kept counting through it would
                // be describing a session that no longer exists.
                if previous != .ready {
                    reconnectAttempt = 0
                    sessionStartedAt = Date()
                    UserDefaults.standard.set(true, forKey: Self.resumeKey)
                    // Record the last-connected timestamp for the Trusted Macs list.
                    if let id = currentHostID {
                        lastConnectedAt[id] = Date()
                        if let data = try? JSONEncoder().encode(lastConnectedAt) {
                            UserDefaults.standard.set(data, forKey: "hostLastConnectedAt")
                        }
                    }
                }
            } else {
                sessionStartedAt = nil
            }

            let userEnded = userEndedSession
            userEndedSession = false
            notifier.sessionMoved(
                from: previous,
                to: phase,
                hostName: hostName ?? "the Mac",
                deliberate: userEnded
            )
            // The same transition, said twice: once as something that can interrupt the user
            // from another app, and once as something they will see without unlocking. Neither
            // is a substitute for the other, and both read from this one place.
            // A session that ended without the user asking is put back on its own. The flag
            // inside `scheduleReconnect` is what decides whether this was theirs — the phase
            // alone cannot tell a drop from a disconnect.
            //
            // Before the activity is told, not after: scheduling is what sets `isReconnecting`,
            // and the card has to go up saying "reconnecting" rather than be taken down and
            // brought back a moment later as though nothing had happened.
            if !phase.holdsSession, !userEnded {
                scheduleReconnect()
            }
            // Held open for as long as there is a session, so the socket outlives the app being
            // on screen. Start before the card rather than after: the card is worth nothing if
            // the session it describes has already been suspended. See ``SessionAudio``.
            if phase.holdsSession {
                SessionAudio.shared.begin()
            } else {
                SessionAudio.shared.end()
            }

            SessionActivity.shared.sessionMoved(
                from: previous,
                to: phase,
                hostName: hostName ?? "the Mac",
                startedAt: sessionStartedAt,
                reconnecting: isReconnecting,
                deliberate: userEnded,
                path: Self.activityPath(connectionPath)
            )

            if !phase.holdsSession {
                // The buttons stop claiming a modifier the moment the link that carried it is
                // gone. Nothing else can: the release would have to travel back over the same
                // connection. Observed on this Mac, the window server keeps the flag until a
                // real key-up arrives, so the Mac may still be holding it — which is why this
                // says so rather than quietly showing the buttons as released.
                if !latchedModifiers.isEmpty {
                    append(note: "The connection ended while \(latchedModifiers.label) was held on the Mac. It may still be held there.")
                }
                latchedModifiers = []
                privacyModeEnabled = false
            }
        case .host(let hello):
            // The host's own name is authoritative. Bonjour is only a hint about where to
            // find it, and it can be stale by minutes.
            hostName = hello.hostName
            currentHostID = hello.serverID
            UserDefaults.standard.set(hello.serverID, forKey: Self.lastHostIDKey)
            if hostNames[hello.serverID] != hello.hostName {
                hostNames[hello.serverID] = hello.hostName
                UserDefaults.standard.set(hostNames, forKey: Self.hostNamesKey)
                publishKnownMacs()
            }
            if let macs = hello.macAddresses, !macs.isEmpty {
                hostMACAddresses[hello.serverID] = macs
                if let data = try? JSONEncoder().encode(hostMACAddresses) {
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
        case .note(let message):
            append(note: message)
        case .remoteNotice(let message):
            remoteNotice = message
        case .clipboard(let text):
            hostClipboard = text
            clipboardPulling = false
            // Every pull is filed, so the next one does not overwrite the last one anywhere but
            // on the phone's own pasteboard.
            rememberClipboard(text)
        case .audio(let event):
            switch event {
            case .config(let config):
                audioPlayer = RemoteAudioPlayer(config: config)
                // A fresh player per stream, so the preference has to be handed to each one.
                audioPlayer?.isMuted = hostAudioMuted
            case .frame(let frame):
                audioPlayer?.enqueue(frame)
            }
        case .terminal(let event):
            apply(terminal: event)
        case .relayQuotaExceeded:
            if storeManager.isPro {
                // Paid — relay doesn't recognise the key yet (no backend). Treat as transient.
                append(note: "Relay quota reached. Your subscription is active; please try again later.")
            } else {
                showPaywall = true
                // Suppress the reconnect ladder: there is nothing to reconnect to.
                userEndedSession = true
                stopReconnecting()
            }
        }
    }

    func apply(_ event: HostBrowser.Event) {
        switch event {
        case .started:
            browseFailed = false
            browseStatus = "Looking for Macs on this network…"
        case .updated(let hosts):
            browseFailed = false
            self.hosts = hosts
            if let pending = pendingHostID, let host = hosts.first(where: { $0.id == pending }) {
                pendingHostID = nil
                connect(to: .discovered(host))
            }
            self.resumeIfNeeded()
            browseStatus = hosts.isEmpty
                ? "No Macs found yet. Make sure Peering is running on your Mac and on the same network."
                : "\(hosts.count) Mac\(hosts.count == 1 ? "" : "s") found"
        case .failed(let message):
            // Bonjour failing is silent on iOS without the local-network permission and the
            // NSBonjourServices entry, so the message is surfaced verbatim rather than
            // smoothed over — the manual address path below is the way past it.
            //
            // Shown even though the browser is already replacing itself: the retry can take half
            // a minute, and a status line that said nothing would leave the user looking at a
            // list that has quietly stopped updating.
            browseFailed = true
            browseStatus = "Browsing failed: \(message)"
        }
    }

    // MARK: - Connecting

    /// Whether a session is up or on its way up. The same question as ``Phase/holdsSession`` —
    /// asked once, answered in one place.
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
            append(note: "Video stream started: \(config.pixelWidth)×\(config.pixelHeight) \(config.codec.rawValue.uppercased())")
        case .frame:
            break // Handled on the network queue; see `connect(to:)`.
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
                    self.updateFrameRate(from: snapshot)
                    self.updateAutoQuality(from: snapshot)

                    let suffix = snapshot.framesDropped > 0 ? " · \(snapshot.framesDropped) dropped" : ""
                    let waiting = snapshot.awaitingKeyframe ? " · waiting for a keyframe" : ""
                    // The *rate* leads, and the running total follows it. "1234 frames" answers
                    // how long the session has been up; the question a picture that looks choppy
                    // actually raises is how many are arriving each second, and only a
                    // difference between two samples can answer it.
                    let rate = self.videoFramesPerSecond > 0
                        ? " · \(Int(self.videoFramesPerSecond.rounded())) fps"
                        : ""
                    self.videoStatus = "\(snapshot.codec.rawValue.uppercased()) \(snapshot.pixelWidth)×\(snapshot.pixelHeight)\(rate) · \(snapshot.framesEnqueued) frames\(suffix)\(waiting)"
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

    func append(note: String) {
        notes.append(note)
        if notes.count > 12 { notes.removeFirst(notes.count - 12) }
    }

    // MARK: - Pairing

}
