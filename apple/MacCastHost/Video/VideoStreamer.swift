import Foundation
import RemoteCore
import os

let streamerLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// Delivers encoded frames to whichever client is attached to the video channel.
final class VideoStreamer: @unchecked Sendable {
    struct Stats: Equatable, Sendable {
        var sent = 0
        var dropped = 0
        var keyframesSent = 0
/// Payload bytes handed to the network, counted on the successful send rather than on submission, so
/// a frame that never left is not counted as bandwidth.
        var bytesSent = 0
        var audioFramesSent = 0
        var audioFramesDropped = 0
        var audioBytesSent = 0
/// Frames discarded because they arrived while a keyframe was owed. Counted apart from ``dropped``
/// because the two say different things: `dropped` means the link is behind, and this means the
/// stream is waiting to restart. A number that is nonzero for long is a stalled capture, not a slow
/// one.
        var droppedAwaitingKeyframe = 0
    }

    let lock = NSLock()
    var peer: PeerConnection?
    var pending: EncodedVideoFrame?
    var pendingAudio: EncodedAudioFrame?
    var audioConfig: AudioStreamConfig?
    var audioConfigOwed = false
    var sentAudioLast = true
    var sending = false
    var _stats = Stats()

    var transport: VideoTransport = .primary
    var controlPeer: PeerConnection?

    var datagrams: VideoDatagramLane?

    var isDirectOpen: Bool { lock.withLock { datagrams }?.isDirectOpen ?? false }

/// The description of the stream being sent, held so it can be re-sent.
    var currentConfig: VideoStreamConfig?
/// The most recent recovery point for the current stream. ScreenCaptureKit emits no new picture for a
/// completely still desktop, so merely asking the encoder for a keyframe can wait forever. A newly
/// attached client gets this one immediately, while the encoder is still asked for a fresh keyframe
/// before any later delta is allowed through.
    var latestKeyframe = DeferredVideoKeyframe()

    var chunkFrameID: UInt32 = 0

    var lastFrameAt: TimeInterval = 0
    var lastKeyframeAt: TimeInterval = 0
    var lastProbeAt: TimeInterval = 0
    var probeTimer: DispatchSourceTimer?

/// How often the transport the session came from is offered a keyframe while video is on the control
/// channel.
    static let probeInterval: TimeInterval = 4

    static let probeQueue = DispatchQueue(label: "pl.dmq.peering.host.video.probe", qos: .utility)

/// Whether the attached client is owed a keyframe before anything else reaches it.
    var awaitingKeyframe = false

    var generation = 0

    /// Asks the capture pipeline for an immediate keyframe.
    let requestKeyframe: @Sendable () -> Void

    init(requestKeyframe: @escaping @Sendable () -> Void) {
        self.requestKeyframe = requestKeyframe
    }

    var stats: Stats { lock.withLock { _stats } }
    var isAttached: Bool { lock.withLock { peer != nil } }


    // MARK: - Frames

    func submit(_ frame: EncodedVideoFrame) {
// Set outside the lock below only when the frame is one the preferred transport is owed, so the send
// itself does not happen while holding it.
        var probe: (lane: Lane, payloads: [Data])?

        let shouldPump = lock.withLock { () -> Bool in
            let now = Self.monotonicNow()
            lastFrameAt = now
            if frame.isKeyframe {
                lastKeyframeAt = now
                latestKeyframe.record(frame)
            }

// With no client there is nothing to send. The latest keyframe above is the one exception: it is the
// recovery point a client needs when the desktop stays still after attaching and ScreenCaptureKit
// therefore produces no replacement frame.
            guard peer != nil else { return false }

// The client's decoder has been reset, and only a keyframe can restart it. A delta sent here is not a
// worse first picture, it is no first picture.
            if awaitingKeyframe {
                guard frame.isKeyframe else {
                    _stats.droppedAwaitingKeyframe += 1
                    return false
                }
                awaitingKeyframe = false
            }

// While video is on the control channel, the transport it came from keeps being offered keyframes,
// see ``probeInterval``. They are not on the shared pump: a lane being probed must not be able to hold
// up the lane the picture is actually on. "The transport it came from" is whichever lane this session
// prefers, so on a relayed session that is the datagram path rather than a connection.
            if transport == .control, frame.isKeyframe, now - lastProbeAt >= Self.probeInterval,
               let lane = primaryLaneLocked() {
                lastProbeAt = now
                probe = (lane, encode(kind: .videoFrame, payload: frame.encoded(), on: lane))
            }

            if let waiting = pending {
// Exactly one of the two is discarded: either the frame that was waiting, or the one that just
// arrived. Either way it is one drop, so this is not conditional on which of them the policy chose.
                pending = VideoDropPolicy.superseded(waiting, by: frame)
                _stats.dropped += 1
            } else {
                pending = frame
            }
            return !sending
        }

        if let probe { send(probe.payloads, on: probe.lane) { _ in } }
        if shouldPump { pump() }
    }




}
