import Foundation
import RemoteCore
import os

private let videoLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// Delivers encoded frames to whichever client is attached to the video channel.
///
/// **The queue holds one frame, not a backlog, and that is the entire design.** A frame that
/// arrives late is worse than a frame that never arrives: the client cannot use a picture of
/// where the screen used to be, and a deep queue converts a slow link into steadily growing
/// latency that never recovers. So when the link backpressures, the newest frame replaces
/// whatever was waiting — subject to ``VideoDropPolicy``, which will not let a keyframe be
/// discarded in favour of a delta.
///
/// Flow control comes from the send completion rather than from a timer or a guess: exactly
/// one frame is in flight at a time, and the next is only chosen once the last is accepted.
/// A frame dropped while one is in flight is never counted as sent.
///
/// Everything is behind ``lock`` because the encoder submits from its own queue while
/// attach/detach arrive on the network queue.
final class VideoStreamer: @unchecked Sendable {
    struct Stats: Equatable, Sendable {
        var sent = 0
        var dropped = 0
        var keyframesSent = 0
        /// Frames discarded because they arrived while a keyframe was owed. Counted apart
        /// from ``dropped`` because the two say different things: `dropped` means the link
        /// is behind, and this means the stream is waiting to restart. A number that is
        /// nonzero for long is a stalled capture, not a slow one.
        var droppedAwaitingKeyframe = 0
    }

    private let lock = NSLock()
    private var peer: PeerConnection?
    private var pending: EncodedVideoFrame?
    private var sending = false
    private var _stats = Stats()

    /// Whether the attached client is owed a keyframe before anything else reaches it.
    ///
    /// **Set by every event that invalidates the client's decoder** — an attach, and a
    /// config change — and cleared by the keyframe that satisfies it. Until then ``submit``
    /// discards deltas, because a delta encodes only the difference from a picture the
    /// client never received: its decoder has nothing to apply it to and shows nothing.
    ///
    /// Asking for a keyframe is not on its own enough, which is what this exists for.
    /// ``requestKeyframe`` is asynchronous — it takes effect on the encoder's *next* output
    /// — while frames the encoder had already finished keep arriving on its callback queue.
    /// The first of those is a delta, it wins the race into `pending`, and it is sent the
    /// moment the config's send completes: the client's first frame is one it cannot decode,
    /// and it waits out the encoder's keyframe interval on a black screen. The request and
    /// the gate are two halves of one fix — the request makes the keyframe arrive soon, the
    /// gate is what stops anything else being first.
    private var awaitingKeyframe = false

    /// Bumped on every attach, detach, and config change. A send completion captures the
    /// value it started under and does nothing if it no longer matches, which is what keeps
    /// a completion from a torn-down connection from resuming the pump for the new one.
    private var generation = 0

    /// Asks the capture pipeline for an immediate keyframe.
    ///
    /// Called when a client attaches and whenever the configuration changes, because both
    /// invalidate every frame the decoder is holding. Without it the client waits for the
    /// encoder's next scheduled keyframe with nothing on screen — the classic "connected but
    /// the screen is black" bug.
    private let requestKeyframe: @Sendable () -> Void

    init(requestKeyframe: @escaping @Sendable () -> Void) {
        self.requestKeyframe = requestKeyframe
    }

    var stats: Stats { lock.withLock { _stats } }
    var isAttached: Bool { lock.withLock { peer != nil } }

    // MARK: - Attachment

    func attach(_ peer: PeerConnection, config: VideoStreamConfig) {
        lock.withLock {
            generation += 1
            self.peer = peer
            pending = nil
            awaitingKeyframe = true
            // Held true until the config lands, so a frame submitted in the meantime queues
            // behind it rather than racing ahead of it. The ordering is the point: a decoder
            // that receives a frame before its parameter sets cannot start.
            sending = true
        }
        sendConfig(config, to: peer)
        requestKeyframe()
        videoLog.notice("video client attached · \(config.pixelWidth)×\(config.pixelHeight) \(config.codec.rawValue, privacy: .public)")
    }

    func detach() {
        let wasAttached = lock.withLock { () -> Bool in
            generation += 1
            let had = peer != nil
            peer = nil
            pending = nil
            sending = false
            return had
        }
        if wasAttached {
            let stats = self.stats
            videoLog.notice("""
                video client detached · sent \(stats.sent, privacy: .public), \
                \(stats.keyframesSent, privacy: .public) keyframe(s), \
                dropped \(stats.dropped, privacy: .public), \
                \(stats.droppedAwaitingKeyframe, privacy: .public) discarded awaiting a keyframe
                """)
        }
    }

    /// Detaches, but only if `peer` is the connection currently attached. Returns whether it
    /// detached.
    ///
    /// A video connection closing is not on its own a reason to stop sending. A client that
    /// reconnects — after a network blip, or after switching away from the app and back —
    /// has a new connection accepted before the old one is reaped, and an unconditional
    /// detach on the old connection's close would tear down the replacement. The two
    /// connections are identical in every way that can be compared by value, right down to
    /// the client key they were authorized under, so identity is the only thing that tells
    /// them apart.
    @discardableResult
    func detach(ifAttachedTo peer: PeerConnection) -> Bool {
        guard lock.withLock({ self.peer === peer }) else { return false }
        detach()
        return true
    }

    /// Replaces the stream configuration, for a capture-source change.
    ///
    /// A new source means new dimensions and new parameter sets, and a decoder whose state
    /// belongs to a different picture entirely. Re-sending the config and forcing a keyframe
    /// is what lets `SCStream.updateContentFilter` swap sources without tearing down the
    /// connection.
    func updateConfig(_ config: VideoStreamConfig) {
        guard let peer = lock.withLock({ self.peer }) else { return }
        lock.withLock {
            generation += 1
            pending = nil
            awaitingKeyframe = true
            sending = true
        }
        sendConfig(config, to: peer)
        requestKeyframe()
        videoLog.notice("video config updated · \(config.pixelWidth)×\(config.pixelHeight)")
    }

    // MARK: - Frames

    /// Offers an encoded frame. Called for every frame the encoder produces, attached or not.
    func submit(_ frame: EncodedVideoFrame) {
        let shouldPump = lock.withLock { () -> Bool in
            // With no client there is nothing to send and nothing worth buffering — a frame
            // held for a client that has not connected yet would be stale by the time it did.
            guard peer != nil else { return false }

            // The client's decoder has been reset, and only a keyframe can restart it. A
            // delta sent here is not a worse first picture, it is no first picture — see
            // ``awaitingKeyframe``.
            if awaitingKeyframe {
                guard frame.isKeyframe else {
                    _stats.droppedAwaitingKeyframe += 1
                    return false
                }
                awaitingKeyframe = false
            }

            if let waiting = pending {
                // Exactly one of the two is discarded: either the frame that was waiting, or
                // the one that just arrived. Either way it is one drop, so this is not
                // conditional on which of them the policy chose.
                pending = VideoDropPolicy.superseded(waiting, by: frame)
                _stats.dropped += 1
            } else {
                pending = frame
            }
            return !sending
        }
        if shouldPump { pump() }
    }

    // MARK: - Sending

    private func sendConfig(_ config: VideoStreamConfig, to peer: PeerConnection) {
        let startedUnder = lock.withLock { generation }
        guard let json = try? JSONEncoder().encode(config) else {
            videoLog.error("could not encode the video config; the client will see no video")
            return
        }
        peer.send(FrameEncoder.encode(Frame(kind: .videoConfig, payload: json))) { [weak self] _ in
            guard let self else { return }
            let current = lock.withLock { () -> Bool in
                guard self.generation == startedUnder else { return false }
                self.sending = false
                return true
            }
            if current { pump() }
        }
    }

    private func pump() {
        let outgoing: (frame: EncodedVideoFrame, peer: PeerConnection, generation: Int)? =
            lock.withLock {
                guard !sending, let peer, let frame = pending else { return nil }
                pending = nil
                sending = true
                return (frame, peer, generation)
            }
        guard let outgoing else { return }

        let payload = FrameEncoder.encode(
            Frame(kind: .videoFrame, payload: outgoing.frame.encoded())
        )
        outgoing.peer.send(payload) { [weak self] error in
            guard let self else { return }

            let stillCurrent = lock.withLock { () -> Bool in
                // The connection this belongs to has been replaced. Resuming here would
                // drive the *new* peer's pump from a dead one's completion.
                guard self.generation == outgoing.generation else { return false }
                self.sending = false
                if error == nil {
                    self._stats.sent += 1
                    if outgoing.frame.isKeyframe { self._stats.keyframesSent += 1 }
                }
                return true
            }

            if let error {
                videoLog.error("video send failed: \(error.localizedDescription, privacy: .public)")
            }
            if stillCurrent { pump() }
        }
    }
}
