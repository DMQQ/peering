import Foundation
import RemoteCore
import os

extension VideoStreamer {
    func attach(_ peer: PeerConnection, config: VideoStreamConfig) {
        let abandoned = lock.withLock { () -> VideoDatagramLane? in
            generation += 1
// The relay's datagram path belongs to the client that asked for it, so it goes when the audience
// changes. Only then: a relayed session's first frames take long enough to prepare that the client's
// request can arrive before this attach does, and a lane cleared unconditionally would take away the
// path the client had just been granted.
            let abandoned = self.peer != nil && self.peer !== peer ? datagrams : nil
            if abandoned != nil { datagrams = nil }
            self.peer = peer
            pending = latestKeyframe.latest(matching: config)
            pendingAudio = nil
            audioConfigOwed = audioConfig != nil
            sentAudioLast = true
            awaitingKeyframe = true
// Held true until the config lands, so a frame submitted in the meantime queues behind it rather
// than racing ahead of it: a decoder that receives a frame before its parameter sets cannot start.
            sending = true
            transport = .primary
            controlPeer = nil
            return abandoned
        }
        abandoned?.cancel()
        stopProbeTimer()
        sendConfig(config, to: peer)
        requestKeyframe()
        streamerLog.notice("video client attached · \(config.pixelWidth)×\(config.pixelHeight) \(config.codec.rawValue, privacy: .public)")
    }

/// Moves video onto the control channel, or back to the transport the session prefers.
    @discardableResult
    func use(transport: VideoTransport, controlPeer: PeerConnection?) -> Bool {
        let (stopped, resend) = lock.withLock {
            () -> (DispatchSourceTimer?, (config: VideoStreamConfig, peer: PeerConnection)?) in
            self.transport = transport
            self.controlPeer = controlPeer
            pending = nil

            guard transport == .control, let controlPeer, let config = currentConfig else {
                let timer = transport == .primary ? probeTimer : nil
                if transport == .primary { probeTimer = nil }
                return (timer, nil)
            }

// The lane is changing, so everything the other one was holding is void: the new decoder has no
// description and no picture, and only a keyframe can give it one. `sending` is held true until the
// description has been written, which stops a frame arriving before the parameter sets that explain
// it.
            awaitingKeyframe = true
            sending = true
            pendingAudio = nil
            audioConfigOwed = audioConfig != nil
            return (nil, (config, controlPeer))
        }
        stopped?.cancel()

        if let resend {
            sendConfig(resend.config, to: resend.peer)
            requestKeyframe()
            ensureProbeTimer()
            streamerLog.notice("video is on the control channel; the preferred transport is probed with keyframes")
            return true
        }

        if transport == .control {
            lock.withLock {
                self.transport = .primary
                self.controlPeer = nil
            }
            streamerLog.notice("the control channel was asked for before the stream had a description")
            return false
        }

        requestKeyframe()
        streamerLog.notice("video is back on the transport the client prefers")
        return true
    }

/// Installs the relay's datagram lane, or takes it away.
    @discardableResult
    func useDatagrams(_ lane: VideoDatagramLane?) -> Bool {
        let previous = lock.withLock { () -> VideoDatagramLane? in
            let previous = datagrams
            datagrams = lane
            guard lane != nil else { return previous }
// Nothing already waiting is discarded, unlike a move to the control channel: the client asked for
// this lane with the stream's description already in hand, so what is queued is decodable on it. Only
// the next picture is gated, and that gate is what makes the new lane start from a keyframe.
            awaitingKeyframe = true
            return previous
        }
        guard previous !== lane else { return lane != nil }
        previous?.cancel()

        guard lane != nil else {
            streamerLog.notice("the relay's video datagram path was taken away")
            return false
        }
        lane?.start()
        requestKeyframe()
        streamerLog.notice("video is on the relay's datagram path")
        return true
    }

/// Whether the encoder has produced anything recently enough for a fallback request to mean
/// something.
    func isProducing(within interval: TimeInterval) -> Bool {
        lock.withLock { peer != nil && Self.monotonicNow() - lastFrameAt <= interval }
    }

    func detach() {
        let (wasAttached, lane) = lock.withLock { () -> (Bool, VideoDatagramLane?) in
            generation += 1
            let had = peer != nil
            let lane = datagrams
            datagrams = nil
            peer = nil
            pending = nil
            pendingAudio = nil
            audioConfigOwed = false
            sending = false
            transport = .primary
            controlPeer = nil
            currentConfig = nil
            return (had, lane)
        }
        lane?.cancel()
        stopProbeTimer()
        if wasAttached {
            let stats = self.stats
            streamerLog.notice("""
                video client detached · sent \(stats.sent, privacy: .public), \
                \(stats.keyframesSent, privacy: .public) keyframe(s), \
                dropped \(stats.dropped, privacy: .public), \
                \(stats.droppedAwaitingKeyframe, privacy: .public) discarded awaiting a keyframe
                """)
        }
    }

/// Detaches, but only if `peer` is the connection currently attached. Returns whether it detached.
    @discardableResult
    func detach(ifAttachedTo peer: PeerConnection) -> Bool {
        guard lock.withLock({ self.peer === peer }) else { return false }
        detach()
        return true
    }

    func updateConfig(_ config: VideoStreamConfig) {
        guard let peer = lock.withLock({ self.peer }) else { return }
        lock.withLock {
            generation += 1
            pending = nil
            latestKeyframe.reset()
            awaitingKeyframe = true
            sending = true
        }
// Sent to `peer`, and by ``sendConfig(_:to:)`` also to the control channel when that is where the
// picture is: a source that changed while the session was in the fallback would otherwise keep
// sending keyframes of a stream nobody has the description for.
        sendConfig(config, to: peer)
        requestKeyframe()
        streamerLog.notice("video config updated · \(config.sourceID, privacy: .public) \(config.pixelWidth)×\(config.pixelHeight)")
    }
}
