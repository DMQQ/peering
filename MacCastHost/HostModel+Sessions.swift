import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import RemoteCore
import os

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

// MARK: - Sessions

extension HostModel {
    /// A session that has begun and has not been written down as finished.
    ///
    /// Persisted as it goes, because a record written only at the end is lost whenever the end
    /// never arrives: the host is quit, crashes, or is rebuilt while a phone is attached, which is
    /// exactly the session someone would want to look up.
    struct OpenSession: Codable {
        var deviceName: String
        var started: Date
        /// The streamer's byte count when this session began. The count is cumulative and never
        /// reset, so a session's cost is the difference between a later read and this.
        var bytesAtStart: Int
        /// The last moment this session was known to be alive. Becomes its end time if no end ever
        /// arrives, which is the honest answer: it was alive then, and nothing since.
        var lastSeen: Date
        /// Bytes counted as of ``lastSeen``. Kept current as the session runs rather than derived at
        /// the end, because a session that never ends has no end to derive it from.
        var bytes: Int
    }

    static let sessionsKey = "Peering.sessions"
    static let openSessionsKey = "Peering.openSessions"
    static let maxSessions = 20

    func saveOpenSessions() {
        guard let data = try? JSONEncoder().encode(openSessions) else { return }
        UserDefaults.standard.set(data, forKey: Self.openSessionsKey)
    }

    func adoptAbandonedSessions() {
        guard !hasAdoptedAbandonedSessions else { return }
        hasAdoptedAbandonedSessions = true
        guard !openSessions.isEmpty else { return }
        // Oldest first, so the list still reads newest-first after each is inserted at the top.
        for open in openSessions.values.sorted(by: { $0.started < $1.started }) {
            record(
                "\(open.deviceName) was still connected when the host last stopped",
                level: .warning
            )
            sessions.insert(
                HostSessionRecord(
                    deviceName: open.deviceName,
                    started: open.started,
                    ended: open.lastSeen,
                    bytes: open.bytes
                ),
                at: 0
            )
        }
        if sessions.count > Self.maxSessions {
            sessions.removeLast(sessions.count - Self.maxSessions)
        }
        openSessions = [:]
        saveOpenSessions()
        saveSessions()
    }

    func saveSessions() {
        if sessions.count > Self.maxSessions {
            sessions.removeLast(sessions.count - Self.maxSessions)
        }
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        }
    }

    func beginSession(id: String, name: String) {
        openSessions[id] = OpenSession(
            deviceName: name,
            started: Date(),
            bytesAtStart: coordinator?.streamStatistics.bytesSent ?? 0,
            lastSeen: Date(),
            bytes: 0
        )
        saveOpenSessions()
        hostLog.notice("session opened for \(id, privacy: .public)")
    }

    /// Keeps the in-flight sessions' figures current.
    ///
    /// Called from the screen watch, which already ticks every two seconds while anybody is
    /// attached. Written every thirtieth tick rather than every one, since this is `UserDefaults`
    /// and a figure half a minute stale is worth more than a write per tick.
    func touchOpenSessions() {
        guard !openSessions.isEmpty, let sent = coordinator?.streamStatistics.bytesSent else { return }
        let now = Date()
        for (id, var open) in openSessions {
            open.lastSeen = now
            open.bytes = max(0, sent - open.bytesAtStart)
            openSessions[id] = open
        }
        saveOpenSessions()
    }

    /// Watches whether the screen being streamed can be seen at all, and says so when it cannot.
    ///
    /// The failure is silent by construction: a sleeping display still produces a healthy stream,
    /// frames on time and at full rate, every one of them black, so from the phone it is
    /// indistinguishable from a broken camera.
    ///
    /// Only ever about a display. An application or a window is drawn by the window server whether
    /// or not a panel is lit, so a picture of one is real with every screen dark.
    func screenNotice() -> NoticePayload? {
        if Self.isScreenLocked {
            // Said on a display too: locking there often sleeps it (the power button always does),
            // and a black picture with no caption reads as a broken stream. The phone hides the
            // caption once Unlock has put the keyboard up on that display.
            if case .display(let id)? = capturingSource {
                return NoticePayload(message: "This Mac is locked.", symbol: "lock.fill", lockedDisplayID: id)
            }
            return NoticePayload(
                message: "This Mac is locked.",
                symbol: "lock.fill",
                lockedDisplayID: CGMainDisplayID()
            )
        }
        guard case .display(let id)? = capturingSource else { return nil }

        // Gone rather than dark: `online` separates the two. A sleeping display is still connected,
        // while a lid shut with no external screen leaves nothing to have a picture of at all. Both
        // arrive at the phone as black and they are not the same problem, since one is a tap away
        // from fixed and the other needs a different source.
        if CGDisplayIsOnline(id) == 0 {
            return NoticePayload(
                message: "That display is no longer connected. Choose another from Sources.",
                symbol: "display.slash"
            )
        }
        if CGDisplayIsAsleep(id) != 0 || CGDisplayIsActive(id) == 0 {
            return NoticePayload(
                message: "This Mac's screen is asleep.",
                symbol: "moon.zzz.fill"
            )
        }
        return nil
    }

    /// Whether the login session is locked: the lock screen, or the screen saver with a password.
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Tells whoever is attached why there is no picture, when the reason is one they cannot see
    /// from where they are.
    ///
    /// The fresh-install failure, and silent on both ends: with Screen Recording not yet allowed,
    /// macOS refuses the stream before a frame exists, so the window goes on saying the Mac is
    /// serving and the phone goes on saying it is opening the video channel. The phone cannot work
    /// it out, since a Mac that cannot capture and one with nothing to show look identical from
    /// there, so the host is the only place the sentence can come from.
    ///
    /// Only for failures with something to say to the far end; ``CaptureError/clientNotice`` decides
    /// which those are. Announced once per problem, not once per attempt, and the record is
    /// per-process on purpose: a grant cannot take effect without a relaunch.
    func announceCaptureProblem(_ error: CaptureError) {
        guard let notice = error.clientNotice, let message = notice.message else { return }
        guard message != announcedCaptureProblem else { return }
        announcedCaptureProblem = message
        server?.broadcastNotice(notice)
        // The Mac's own activity list gets the line that says the other device was told.
        record("Told the connected device why there is no picture.", level: .warning)
    }

    /// Runs ``screenNotice()`` while anyone is attached.
    ///
    /// Nobody attached means nobody to tell.
    func startScreenWatch() {
        guard screenWatchTask == nil else { return }
        screenWatchTask = Task { [weak self] in
            var announced: NoticePayload?
            var announcedTo = 0
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }

                // Every thirtieth tick of two seconds, so an abandoned session still has a
                // believable end time and size rather than a zero.
                ticks += 1
                if ticks % 30 == 0 { self.touchOpenSessions() }

                let notice = self.screenNotice()
                // Also when a phone joins, since a notice is only sent on a change and the one
                // that just connected never heard the last.
                let clients = self.connectedClients.count
                if notice != announced || clients != announcedTo {
                    let wasSayingSomething = announced?.message != nil
                    announced = notice
                    announcedTo = clients
                    self.server?.broadcastNotice(notice ?? NoticePayload(message: nil))
                    if let message = notice?.message {
                        self.record("Screen not visible · \(message)", level: .warning)
                    } else if wasSayingSomething {
                        // It said so when the screen went dark, so it owes the all-clear.
                        self.record("Screen visible again")
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopScreenWatch() {
        screenWatchTask?.cancel()
        screenWatchTask = nil
    }

    func endSession(id: String) {
        guard let open = openSessions.removeValue(forKey: id) else {
            hostLog.notice("session closed for \(id, privacy: .public) with nothing open for it")
            return
        }
        let sent = coordinator?.streamStatistics.bytesSent ?? open.bytesAtStart
        sessions.insert(
            HostSessionRecord(
                deviceName: open.deviceName,
                started: open.started,
                ended: Date(),
                bytes: max(0, sent - open.bytesAtStart)
            ),
            at: 0
        )
        if sessions.count > Self.maxSessions {
            sessions.removeLast(sessions.count - Self.maxSessions)
        }
        saveOpenSessions()
        saveSessions()
        hostLog.notice("session recorded · \(self.sessions.count, privacy: .public) kept")
    }

    /// Held while at least one client is connected, released when the last one disconnects: the
    /// display stays lit so ScreenCaptureKit does not turn a healthy stream into black frames.
    func acquireSleepAssertion() {
        guard sleepAssertionID == 0 else { return }
        let reason = "MacCast session active" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )
        if result != kIOReturnSuccess {
            hostLog.notice("could not acquire sleep assertion (IOReturn \(result, privacy: .public))")
        }
    }

    /// Lights a display that went dark while nobody was connected.
    ///
    /// The assertion above only keeps a lit display lit. A Mac that slept its display overnight and
    /// is awake enough to answer the network stays dark when a phone connects, and the picture is
    /// black or absent until somebody touches it, which is the one thing a phone cannot do.
    func wakeDisplayIfAsleep() {
        guard CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { return }
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(
            "Peering connection" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        hostLog.notice("display was asleep; declared user activity to wake it")
    }

    func releaseSleepAssertion() {
        guard sleepAssertionID != 0 else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = 0
    }

    /// Held while a chat session is working, released when the last one stops.
    ///
    /// A different assertion from the session one above, and a different type: that one is about
    /// keeping a *display* lit so capture has something to encode, and this one is about the
    /// machine not going to sleep under a CLI the user left running. Idle sleep is what is being
    /// refused here, which is what `caffeinate -i` takes; the lid-close switch is the user's own
    /// preference and stays out of it.
    func setAgentActivity(_ active: Bool) {
        if active {
            guard agentSleepAssertionID == 0 else { return }
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Peering is running an agent" as CFString,
                &agentSleepAssertionID
            )
            if result != kIOReturnSuccess {
                hostLog.notice("could not acquire the agent sleep assertion (IOReturn \(result, privacy: .public))")
            }
        } else {
            guard agentSleepAssertionID != 0 else { return }
            IOPMAssertionRelease(agentSleepAssertionID)
            agentSleepAssertionID = 0
        }
    }
}
