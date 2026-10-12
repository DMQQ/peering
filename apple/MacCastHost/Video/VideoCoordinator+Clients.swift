import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import RemoteCore
import os

extension VideoCoordinator {
    func handleVideoConnection(_ peer: PeerConnection) {
// Weak, because the connection owns this closure. A strong capture would keep the connection alive
// for as long as the streamer holds the peer, which is exactly the leak that makes a disconnected
// client keep receiving frames.
        let announced = peer.onClose
        peer.onClose = { [weak self, weak peer] error in
            announced?(error)
            guard let peer else { return }
            self?.videoPeerClosed(peer)
        }
        serve(peer)
    }

/// Attaches a client's video connection, or holds it until the stream has a description.
    func serve(_ peer: PeerConnection) {
        let config = adapter.config
        lock.withLock {
            audience.connected(peer, described: config != nil)
            scheduleEnsureCapturingLocked(generation: audience.generation)
        }

        if let config {
            streamer.attach(peer, config: config)
        }
    }

/// Turns the picture on or off for one client, and touches nothing else.
    func setVideoEnabled(_ enabled: Bool, clientKey: Data?) {
        if enabled {
            resumeVideo(clientKey: clientKey)
        } else {
            pauseVideo(clientKey: clientKey)
        }
    }

/// Stops sending frames to a client, keeping its connection.
    func pauseVideo(clientKey: Data?) {
        let attached = lock.withLock { () -> PeerConnection? in
            guard let served = audience.served, served.peerPublicKey == clientKey else {
// Not a client this Mac is sending frames to. The picture is one stream and one client is
// served at a time, so a second phone that never had it has nothing to stop.
                return nil
            }

            let seat = audience.pause(served)
// The bitrate and the lane were chosen for a link that is about to carry nothing. Left standing, the
// picture that comes back would come back capped to the control channel because of a measurement taken
// before the pause.
            forgetTransportChoiceLocked()
            scheduleStopIfIdleLocked(generation: audience.generation)
            return seat == .attached ? served : nil
        }

        guard let attached else { return }
        // Only if this connection is the one being served. See `detach(ifAttachedTo:)`.
        _ = streamer.detach(ifAttachedTo: attached)
        coordinatorLog.notice("video paused by the client · its session stays up")
    }

/// Starts sending frames to a client that has asked for them again.
    func resumeVideo(clientKey: Data?) {
        let resumed = lock.withLock {
            audience.pausedConnections.first { $0.peerPublicKey == clientKey }
        }
        guard let resumed else { return }
        serve(resumed)
    }

/// A client's video connection went away.
    func videoPeerClosed(_ peer: PeerConnection) {
        let seat = lock.withLock { () -> VideoAudience<PeerConnection>.Seat in
            let departure = audience.closed(peer)

// A paused connection was never part of the audience, and an unrelated socket may be one this Mac
// deliberately stopped sending to. Neither changes what the capture is doing, and in particular
// neither advances the generation: a queued start belonging to the connection being served now would
// be discarded, and a client asking for a picture would be left with a capture that never starts.
            guard departure == .waiting || departure == .attached else { return departure }

            chosenSource = nil
// And so does a transport choice. Left standing, the next client, which has asked for nothing, would
// be served a capped picture on the control channel because of a decision somebody else made about a
// link that no longer exists.
            forgetTransportChoiceLocked()
            scheduleStopIfIdleLocked(generation: audience.generation, after: Self.keepCapturingAfterDrop)
            return departure
        }

        switch seat {
        case .attached:
            // Only if this connection is the one being served. See `detach(ifAttachedTo:)`.
            _ = streamer.detach(ifAttachedTo: peer)
            coordinatorLog.notice("video client disconnected")
        case .waiting:
            coordinatorLog.notice("waiting video client disconnected")
        case .unrelated, .paused:
            break
        }
    }

    /// Appends work while `lock` is held. The operation itself never runs under the lock.
    func scheduleLifecycleLocked(_ operation: @escaping @Sendable () async -> Void) {
        let previous = lifecycleTail
        lifecycleTail = Task {
            if let previous { await previous.value }
            await operation()
        }
    }

    /// How long a freshly attached client is given to say what it wants before this Mac picks
    /// for it.
    static let firstAskGrace = Duration.seconds(1)

    func scheduleEnsureCapturingLocked(generation: UInt64) {
        recovery.reset()
        scheduleLifecycleLocked { [weak self] in
            guard let self, self.hasAudience(generation: generation) else { return }

// A client that has just attached has usually already said what it wants. The catalogue goes out the
// moment it connects, and what comes back is the source it was last on, usually a mosaic. Starting the
// default display in the meantime builds a stream that is thrown away a round trip later, and the phone
// watches it happen: a desktop appears, and then the arrangement it was waiting for.
            if self.lock.withLock({ self.chosenSource }) == nil {
                try? await Task.sleep(for: Self.firstAskGrace)
                guard self.hasAudience(generation: generation) else { return }
            }

            do {
                try await self.ensureCapturing()
                guard self.hasAudience(generation: generation) else { return }
                self.pipeline.requestKeyframe()
            } catch {
                self.onFailure?(error as? CaptureError ?? .encodingFailed("\(error)"))
            }
        }
    }

    /// How long capture outlives a viewer that dropped, so one that reconnects gets a keyframe at
    /// once instead of waiting for a new stream. Only for a connection that closed: a pause stops
    /// at once, because saving the battery is what it was asked for.
    static let keepCapturingAfterDrop = Duration.seconds(15)

    /// Not a sleep on the lifecycle queue, which would hold up the next viewer's start: the stop is
    /// queued when the time is up, and only if nobody has attached since.
    func scheduleStopIfIdleLocked(generation: UInt64, after delay: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.lock.withLock {
                guard self.audience.generation == generation else { return }
                self.scheduleStopIfIdleLocked(generation: generation)
            }
        }
    }

    func scheduleStopIfIdleLocked(generation: UInt64) {
        scheduleLifecycleLocked { [weak self] in
            guard let self, self.isIdle(generation: generation) else { return }
            self.cancelWatchdog()
            await self.pipeline.stop()
            self.adapter.forget()
            let remainsIdle = self.lock.withLock { () -> Bool in
                self.currentSource = nil
                return self.audience.generation == generation && self.audience.isIdle
            }
            self.onInputTransform?(nil)
            if remainsIdle {
// A client that asked for no frames is still here, and the status line has to be able to tell that
// from a client that left: "no video clients" over a session that is still up reads as a bug.
                let paused = self.lock.withLock { !self.audience.pausedConnections.isEmpty }
                let reason = paused
                    ? "Capture stopped · paused by the client"
                    : "Capture stopped · no video clients"
                self.onStatus?(reason)
                coordinatorLog.notice("\(reason, privacy: .public)")
            }
        }
    }

    func hasAudience(generation: UInt64) -> Bool {
        lock.withLock {
            audience.generation == generation && !audience.isIdle
        }
    }

    func isIdle(generation: UInt64) -> Bool {
        lock.withLock {
            audience.generation == generation && audience.isIdle
        }
    }
}
