import CryptoKit
import Crypto
import Foundation
import Network
import Security
import os

extension ClientSession {
    /// Watches the picture for a blocked video transport, which looks from both sides like a working session. Rules are in ``VideoFallbackPolicy``.
    func startVideoWatch() {
        lock.lock()
        // Measured from the moment the session became ready: three seconds of a healthy control channel with nothing arriving is the session-start probe.
        lastPictureAt = Self.monotonicNow()
        lastControlReplyAt = nil
        readyAt = nil
        lastSilenceCheckAt = nil
        silenceRestartedAt = nil
        fallbackPolicy.reset()
        guard videoWatchTask == nil else { lock.unlock(); return }
        let task = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.evaluateVideoTransport()
                self.failIfControlHasGoneQuiet()
                ticks += 1
                if ticks % 2 == 0 { self.reportDatagramCounts() }
            }
        }
        videoWatchTask = task
        lock.unlock()
    }

    /// Forgets the fallback's state and hands back the watch to cancel. Call with `lock` held and cancel the task after releasing it: `NSLock` is not recursive.
    func stopVideoWatchLocked() -> Task<Void, Never>? {
        let task = videoWatchTask
        videoWatchTask = nil
        fallbackPolicy.reset()
        lastPictureAt = nil
        lastControlReplyAt = nil
        readyAt = nil
        lastSilenceCheckAt = nil
        silenceRestartedAt = nil
        videoChunks = VideoChunkReassembler()
        // A payload put back across two sessions would be made of two different Macs' pasteboards.
        clipboardChunks = ClipboardTransfer.reassembler()
        announcedTransport = .primary
        videoReconnectLadder.reset()
        // A new session starts wanting a picture. Left standing, a session that had been paused and
        // then reused would open no video socket for the whole of its second life.
        wantsPicture = true
        wantsVideoDatagrams = false
        videoOpener = nil
        // Dropped with the lane it belongs to. The sealer in particular: a new session mints a new
        // secret, so keeping this one would have the next session sealing under a key the Mac no
        // longer holds.
        videoSealer = nil
        pathPingLedger = PingLedger()
        pathLatency = LatencyWindow(length: ClientSession.latencyWindow)
        datagramFailures = 0
        reportedDatagramFailure = false
        lanePingTask?.cancel()
        lanePingTask = nil
        return task
    }

    /// Ends a session the network has stopped carrying without saying so: after a network change nothing fails, and the picture stays on its last frame. A session that recovers within the window is left alone.
    /// A backgrounded app is frozen by iOS with its sockets open, and the first check after it runs again would read that time as silence. Ping instead, and judge by the answer.
    func failIfControlHasGoneQuiet() {
        let now = Self.monotonicNow()
        lock.lock()
        let previousCheckAt = lastSilenceCheckAt
        let verdict = Self.controlSilence.judge(
            isReady: state == .ready,
            readyAt: readyAt,
            lastReplyAt: lastControlReplyAt,
            restartedAt: silenceRestartedAt,
            previousCheckAt: previousCheckAt,
            now: now
        )
        lastSilenceCheckAt = now
        if verdict == .resumedFromFreeze { silenceRestartedAt = now }
        let silentSince = lastControlReplyAt ?? readyAt
        lock.unlock()

        switch verdict {
        case .healthy:
            return
        case .resumedFromFreeze:
            let frozenFor = previousCheckAt.map { Int(now - $0) } ?? 0
            clientSessionLog.notice("the app was not running for \(frozenFor, privacy: .public)s; asking the Mac instead of judging by the silence")
            sendPing()
        case .expired:
            guard let silentSince else { return }
            clientSessionLog.error("the control channel has not answered for \(Int(now - silentSince), privacy: .public)s; failing the session")
            fail("The Mac stopped answering. It may have moved networks, or the connection was interrupted.", reason: .unresponsive)
        }
    }

    func evaluateVideoTransport() {
        let now = Self.monotonicNow()
        lock.lock()
        let decision = fallbackPolicy.advance(
            now: now,
            lastPictureAt: lastPictureAt,
            lastControlReplyAt: lastControlReplyAt,
            applies: _videoFallbackEnabled && state == .ready
        )
        lock.unlock()

        switch decision {
        case .none:
            break

        case .useControlChannel:
            // A request, not an instruction: the host will not move a picture it is not producing. The ask repeats on its own schedule, see ``VideoFallbackPolicy``, while the screen is told once.
            connection()?.send(.videoTransport, VideoTransportRequest(
                transport: .control,
                reason: "no picture for \(Int(VideoFallbackPolicy.silenceBeforeFallback))s "
                    + "on a control channel that is answering"
            ))
            // The counters ride with the note: a failed lane is only explicable with the numbers from when it failed, and settings cannot be opened mid-session.
            announce(.control, note: "No video is arriving. Asking the Mac to send the picture over the control channel. Datagram lane: \(datagramCounts.summary).")

        case .usePrimaryTransport:
            connection()?.send(.videoTransport, VideoTransportRequest(
                transport: .primary,
                reason: "video is arriving again on the transport it prefers"
            ))
            announce(.primary, note: "Video is arriving again on the faster path. Datagram lane: \(datagramCounts.summary).")
        }
    }

    /// Hands the lane's counters to the watcher. Silent until there is a lane: zeros would read as a present, idle lane.
    func reportDatagramCounts() {
        guard lock.withLock({ videoDatagrams != nil }) else { return }
        emit(.datagramCounts(datagramCounts))
    }

    /// Says which lane the picture is on, once per change: the ask repeats but the note is read by a person.
    func announce(_ transport: VideoTransport, note: String) {
        let changed = lock.withLock { () -> Bool in
            guard announcedTransport != transport else { return false }
            announcedTransport = transport
            return true
        }
        guard changed else { return }
        emit(.video(.transport(transport)))
        emit(.note(note))
    }

    func note(pictureOn transport: VideoTransport) {
        lock.withLock {
            lastPictureAt = Self.monotonicNow()
            if transport == .primary { fallbackPolicy.notePrimaryPicture() }
        }
    }

    /// Monotonic seconds: `DispatchTime` rather than `Date`, so a clock sync cannot look like silence.
    static func monotonicNow() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
