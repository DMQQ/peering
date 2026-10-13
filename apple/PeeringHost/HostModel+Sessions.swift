import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import RemoteCore
import os

private let hostLog = Logger(subsystem: "pl.dmq.peering.host", category: "session")

// MARK: - Sessions

extension HostModel {
    /// Persisted as it goes: a session whose end never arrives (quit, crash, rebuild) is the one worth looking up.
    struct OpenSession: Codable {
        var deviceName: String
        var started: Date
        /// Cumulative and never reset, so the session cost is a later read minus this.
        var bytesAtStart: Int
        /// Becomes the end time if no end ever arrives.
        var lastSeen: Date
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
        HostTelemetry.sessionStarted(clientID: id, droppedFrames: coordinator?.streamStatistics.dropped ?? 0)
        saveOpenSessions()
        hostLog.notice("session opened for \(id, privacy: .public)")
    }

    /// Written every thirtieth screen-watch tick: UserDefaults writes cost more than half-minute staleness.
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

    /// The failure is silent: a sleeping display still streams healthy black frames. Only about displays; an application or window renders regardless of panel power.
    func screenNotice() -> NoticePayload? {
        if Self.isScreenLocked {
            // Said on a display too: locking often sleeps it, and a black picture with no caption reads as a broken stream.
            if case .display(let id)? = capturingSource {
                return NoticePayload(message: "This Mac is locked.", symbol: "lock.fill", lockedDisplayID: id, code: NoticeCode.screenLocked.rawValue)
            }
            return NoticePayload(
                message: "This Mac is locked.",
                symbol: "lock.fill",
                lockedDisplayID: CGMainDisplayID(),
                code: NoticeCode.screenLocked.rawValue
            )
        }
        guard case .display(let id)? = capturingSource else { return nil }

        // Gone rather than dark: online separates a sleeping display (a tap away) from a shut lid with no external screen.
        if CGDisplayIsOnline(id) == 0 {
            return NoticePayload(
                message: "That display is no longer connected. Choose another from Sources.",
                symbol: "display.slash",
                code: NoticeCode.displayDisconnected.rawValue
            )
        }
        if CGDisplayIsAsleep(id) != 0 || CGDisplayIsActive(id) == 0 {
            return NoticePayload(
                message: "This Mac's screen is asleep.",
                symbol: "moon.zzz.fill",
                code: NoticeCode.screenAsleep.rawValue
            )
        }
        return nil
    }

    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// The fresh-install failure: without Screen Recording macOS refuses the stream silently on both ends, so only the host can say why. Announced once per problem; the record is per-process because a grant needs a relaunch.
    func announceCaptureProblem(_ error: CaptureError) {
        guard let notice = error.clientNotice, let message = notice.message else { return }
        guard message != announcedCaptureProblem else { return }
        announcedCaptureProblem = message
        server?.broadcastNotice(notice)
        record("Told the connected device why there is no picture.", level: .warning)
    }

    /// The notice text is the English the phone maps; the feed names the same causes in the Mac's language.
    private static func screenNotVisible(because message: String) -> LocalizedStringResource {
        switch message {
        case "This Mac is locked.": "Screen not visible · This Mac is locked."
        case "That display is no longer connected. Choose another from Sources.":
            "Screen not visible · That display is no longer connected. Choose another from Sources."
        case "This Mac's screen is asleep.": "Screen not visible · This Mac's screen is asleep."
        default: "Screen not visible · \(message)"
        }
    }

    func startScreenWatch() {
        guard screenWatchTask == nil else { return }
        screenWatchTask = Task { [weak self] in
            var announced: NoticePayload?
            var announcedTo = 0
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }

                // Every thirtieth tick, so an abandoned session has a believable end time.
                ticks += 1
                if ticks % 30 == 0 { self.touchOpenSessions() }

                let notice = self.screenNotice()
                // Also when a phone joins: notices are sent only on change.
                let clients = self.connectedClients.count
                if notice != announced || clients != announcedTo {
                    let wasSayingSomething = announced?.message != nil
                    announced = notice
                    announcedTo = clients
                    self.server?.broadcastNotice(notice ?? NoticePayload(message: nil))
                    if let message = notice?.message {
                        self.record(Self.screenNotVisible(because: message), level: .warning)
                    } else if wasSayingSomething {
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
        HostTelemetry.sessionEnded(
            clientID: id,
            bytesSent: Int64(max(0, (coordinator?.streamStatistics.bytesSent ?? 0) - (openSessions[id]?.bytesAtStart ?? 0))),
            droppedFrames: coordinator?.streamStatistics.dropped ?? 0,
            directPathOpen: coordinator?.isDirectPathOpen ?? false
        )
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

    /// The assertion only keeps a lit display lit; a display slept overnight stays dark when a phone connects.
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

    /// Idle sleep only (caffeinate -i): the lid-close switch is the user own preference.
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
