import Foundation
import RemoteCore
import os

private let videoLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// Delivers encoded frames to whichever client is attached to the video channel.
///
/// The queue holds one frame, not a backlog, and that is the entire design. A frame that arrives
/// late is worse than a frame that never arrives: the client cannot use a picture of where the
/// screen used to be, and a deep queue converts a slow link into steadily growing latency that never
/// recovers. So when the link backpressures the newest frame replaces whatever was waiting, subject
/// to ``VideoDropPolicy``, which will not let a keyframe be discarded in favour of a delta.
///
/// Flow control comes from the send completion rather than from a timer or a guess: exactly one frame
/// is in flight at a time, and the next is only chosen once the last is accepted. A frame dropped
/// while one is in flight is never counted as sent.
///
/// Everything is behind ``lock`` because the encoder submits from its own queue while attach/detach
/// arrive on the network queue.
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
/// Sound's share of ``bytesSent``, counted the same way and apart from it so that a session's total
/// can be reported as one figure while this one is still there to be checked.
        var audioBytesSent = 0
/// Frames discarded because they arrived while a keyframe was owed. Counted apart from ``dropped``
/// because the two say different things: `dropped` means the link is behind, and this means the
/// stream is waiting to restart. A number that is nonzero for long is a stalled capture, not a slow
/// one.
        var droppedAwaitingKeyframe = 0
    }

    private let lock = NSLock()
    private var peer: PeerConnection?
    private var pending: EncodedVideoFrame?
    private var pendingAudio: EncodedAudioFrame?
    private var audioConfig: AudioStreamConfig?
    private var audioConfigOwed = false
    private var sentAudioLast = true
    private var sending = false
    private var _stats = Stats()

    /// Where video is going, and the connection that carries it when that is the control
    /// channel. See ``use(transport:controlPeer:)``.
    private var transport: VideoTransport = .primary
    private var controlPeer: PeerConnection?

/// The relay's datagram path, when this session has one.
///
/// It is the transport the session prefers: on a relayed session the client has no connection of its
/// own to receive video on, so the choice this stands for is between sealed datagrams and the control
/// stream everyone's input shares. Nil on every direct session, and on a relayed one until the client
/// asks for the lane, which is a request like every other move between lanes. See ``useDatagrams(_:)``.
    private var datagrams: VideoDatagramLane?

/// The description of the stream being sent, held so it can be re-sent.
///
/// Parameter sets are out of band in H.264, so a decoder that has never been told them cannot start
/// from a keyframe however many arrive. A client asking for the fallback has by definition not been
/// receiving this stream, so the switch has to carry the description across with it.
    private var currentConfig: VideoStreamConfig?
/// The most recent recovery point for the current stream. ScreenCaptureKit emits no new picture for a
/// completely still desktop, so merely asking the encoder for a keyframe can wait forever. A newly
/// attached client gets this one immediately, while the encoder is still asked for a fresh keyframe
/// before any later delta is allowed through.
    private var latestKeyframe = DeferredVideoKeyframe()

    /// Distinguishes the chunks of one frame from the chunks of the next on the wire.
    private var chunkFrameID: UInt32 = 0

    /// When a frame was last produced, when one was last sent to the transport the session
    /// came from, and the timer that keeps that transport probed.
    private var lastFrameAt: TimeInterval = 0
    private var lastKeyframeAt: TimeInterval = 0
    private var lastProbeAt: TimeInterval = 0
    private var probeTimer: DispatchSourceTimer?

/// How often the transport the session came from is offered a keyframe while video is on the control
/// channel.
///
/// This is the price of knowing the path recovered. A datagram path has no acknowledgement: the host
/// cannot ask whether anything is arriving and the client cannot tell it, so the only evidence either
/// end will accept is a picture that crosses. A keyframe is also exactly what a stream restarting
/// needs, so the probe doubles as the first frame of the recovered picture rather than being waste.
///
/// The rate is deliberately low: on a blocked network these are dropped at the first router, so the
/// whole cost is the encoder's work.
    private static let probeInterval: TimeInterval = 4

    /// Where the probe timer runs. A queue of its own rather than the capture queue, which is
    /// busy encoding, or the server queue, which is the one this exists to keep clear.
    private static let probeQueue = DispatchQueue(label: "pl.dmq.peering.host.video.probe", qos: .utility)

/// Whether the attached client is owed a keyframe before anything else reaches it.
///
/// Set by every event that invalidates the client's decoder, an attach and a config change, and
/// cleared by the keyframe that satisfies it. Until then ``submit`` discards deltas, because a delta
/// encodes only the difference from a picture the client never received: its decoder has nothing to
/// apply it to and shows nothing.
///
/// Asking for a keyframe is not on its own enough. ``requestKeyframe`` is asynchronous, taking effect
/// on the encoder's next output, while frames the encoder had already finished keep arriving on its
/// callback queue. The first of those is a delta, it wins the race into `pending`, and the client's
/// first frame is one it cannot decode. The request makes the keyframe arrive soon; the gate is what
/// stops anything else being first.
    private var awaitingKeyframe = false

/// Bumped on every attach, detach, and config change. A send completion captures the value it started
/// under and does nothing if it no longer matches, which keeps a completion from a torn-down
/// connection from resuming the pump for the new one.
    private var generation = 0

    /// Asks the capture pipeline for an immediate keyframe.
    ///
    /// Called when a client attaches and whenever the configuration changes, because both
    /// invalidate every frame the decoder is holding. Without it the client waits for the
    /// encoder's next scheduled keyframe with nothing on screen, the classic "connected but
    /// the screen is black" bug.
    private let requestKeyframe: @Sendable () -> Void

    init(requestKeyframe: @escaping @Sendable () -> Void) {
        self.requestKeyframe = requestKeyframe
    }

    var stats: Stats { lock.withLock { _stats } }
    var isAttached: Bool { lock.withLock { peer != nil } }

    // MARK: - Attachment

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
// A client that has just attached has asked for nothing, and the fallback is a request rather than a
// property of the connection. Anything a previous client asked for goes with it.
            transport = .primary
            controlPeer = nil
            return abandoned
        }
        abandoned?.cancel()
        stopProbeTimer()
        sendConfig(config, to: peer)
        requestKeyframe()
        videoLog.notice("video client attached · \(config.pixelWidth)×\(config.pixelHeight) \(config.codec.rawValue, privacy: .public)")
    }


/// Moves video onto the control channel, or back to the transport the session prefers.
///
/// Called only when a client asks, and the asymmetry is deliberate: the host cannot tell a datagram
/// that arrived from one that a network dropped, so it has no way to decide this for itself.
///
/// The frame waiting for the other lane is dropped rather than carried over. It was measured against
/// a different queue and would arrive on the new lane as the picture after the config that follows
/// this switch, which is the one ordering a decoder cannot survive.
///
/// - Returns: whether the move was made. The caller holds other state describing the same decision, a
///   bitrate ceiling most of all, and it must not go on holding it about a lane the streamer refused
///   to move to.
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
// The audio description is owed on this lane for the same reason the video one is: the client asking
// for the fallback has usually been receiving neither, and an audio frame without its format is a
// frame the renderer has to throw away.
            pendingAudio = nil
            audioConfigOwed = audioConfig != nil
            return (nil, (config, controlPeer))
        }
        stopped?.cancel()

        if let resend {
            sendConfig(resend.config, to: resend.peer)
            requestKeyframe()
            ensureProbeTimer()
            videoLog.notice("video is on the control channel; the preferred transport is probed with keyframes")
            return true
        }

        if transport == .control {
// Asked for the control channel with nothing to describe: a stream that has not produced its first
// frame yet. There is nothing to move, and the client will ask again, by which time there is.
            lock.withLock {
                self.transport = .primary
                self.controlPeer = nil
            }
            videoLog.notice("the control channel was asked for before the stream had a description")
            return false
        }

// Handed a keyframe rather than whatever comes next. The lane has been losing everything for a while
// and the client may be holding a picture older than the one the next delta refers to, so the first
// frame back is a recovery point.
        requestKeyframe()
        videoLog.notice("video is back on the transport the client prefers")
        return true
    }

/// Installs the relay's datagram lane, or takes it away.
///
/// Called when a client asks for one and the host agrees, and called with `nil` when the session that
/// owns it ends.
///
/// The picture on the new path starts from a keyframe, which is what ``awaitingKeyframe`` is set for:
/// a datagram lane loses packets as a matter of course, and a client whose first datagram is a delta
/// has nothing to apply it to until the encoder's next keyframe. The description is not re-sent, and
/// deliberately: the client asks for this lane only once it has received one, so it holds the
/// parameter sets for exactly the stream the new lane carries.
///
/// - Returns: whether a lane is installed now.
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
            videoLog.notice("the relay's video datagram path was taken away")
            return false
        }
        lane?.start()
// The lane's first frame has to be one a decoder can start from, or the client waits out the
// encoder's keyframe interval on a path that is working.
        requestKeyframe()
        videoLog.notice("video is on the relay's datagram path")
        return true
    }

/// Whether the encoder has produced anything recently enough for a fallback request to mean
/// something.
///
/// A Mac that has produced nothing for a while, a still screen or a capture that never started,
/// cannot tell a network dropping the picture from there being no picture to drop, and moving a
/// stream that is producing nothing would cap the rate and change nothing else. So the host declines,
/// and the client asks again in a few seconds.
    func isProducing(within interval: TimeInterval) -> Bool {
        lock.withLock { peer != nil && Self.monotonicNow() - lastFrameAt <= interval }
    }

    func detach() {
        let (wasAttached, lane) = lock.withLock { () -> (Bool, VideoDatagramLane?) in
            generation += 1
            let had = peer != nil
// The datagram path belongs to the session that asked for it. Left standing, the next client, which
// has asked for nothing, would be served its picture by a socket the relay still associates with the
// client that has gone.
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
            videoLog.notice("""
                video client detached · sent \(stats.sent, privacy: .public), \
                \(stats.keyframesSent, privacy: .public) keyframe(s), \
                dropped \(stats.dropped, privacy: .public), \
                \(stats.droppedAwaitingKeyframe, privacy: .public) discarded awaiting a keyframe
                """)
        }
    }

/// Detaches, but only if `peer` is the connection currently attached. Returns whether it detached.
///
/// A video connection closing is not on its own a reason to stop sending. A client that reconnects,
/// after a network blip or after switching away from the app and back, has a new connection accepted
/// before the old one is reaped, and an unconditional detach on the old connection's close would tear
/// down the replacement. The two are identical in every way that can be compared by value, so
/// identity is the only thing that tells them apart.
    @discardableResult
    func detach(ifAttachedTo peer: PeerConnection) -> Bool {
        guard lock.withLock({ self.peer === peer }) else { return false }
        detach()
        return true
    }

/// Replaces the stream configuration, for a capture-source change.
///
/// A new source means new dimensions and new parameter sets, and a decoder whose state belongs to a
/// different picture entirely. Re-sending the config and forcing a keyframe is what lets
/// `SCStream.updateContentFilter` swap sources without tearing down the connection.
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
        videoLog.notice("video config updated · \(config.sourceID, privacy: .public) \(config.pixelWidth)×\(config.pixelHeight)")
    }

    // MARK: - Frames

    /// Offers an encoded frame. Called for every frame the encoder produces, attached or not.
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

    // MARK: - Probes

    /// Starts the timer that keeps the preferred transport unreliably informed.
    private func ensureProbeTimer() {
        lock.lock()
        guard probeTimer == nil, peer != nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: Self.probeQueue)
        timer.schedule(
            deadline: .now() + Self.probeInterval,
            repeating: Self.probeInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in self?.askForAProbeKeyframe() }
// Resumed before it is stored, so every reference anyone else can reach is a live one: a suspended
// dispatch source that is cancelled and released is a crash.
        timer.resume()
        probeTimer = timer
        lock.unlock()
    }

    private func stopProbeTimer() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            let timer = probeTimer
            probeTimer = nil
            return timer
        }
        timer?.cancel()
    }

/// Asks the encoder for a keyframe if nothing has been offered to the preferred transport for a whole
/// interval.
///
/// A still screen produces no frames at all, ScreenCaptureKit reports "nothing changed" rather than a
/// picture, so a probe that only waited for the encoder's next keyframe would wait forever on exactly
/// the quiet session a user is most likely to leave open.
    private func askForAProbeKeyframe() {
        let now = Self.monotonicNow()
        let ask = lock.withLock { () -> Bool in
            guard transport == .control, peer != nil else { return false }
            return now - max(lastProbeAt, lastKeyframeAt) >= Self.probeInterval
        }
        if ask { requestKeyframe() }
    }

    private static func monotonicNow() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: - Sending

    private func sendConfig(_ config: VideoStreamConfig, to peer: PeerConnection) {
        guard let json = try? JSONEncoder().encode(config) else {
            videoLog.error("could not encode the video config; the client will see no video")
            return
        }

// The lane the picture is on is written last, because it is the one whose acceptance resumes the
// pump. A lane being probed with keyframes is written first and told as well: a keyframe from a new
// stream cannot be decoded against the previous stream's parameter sets, so those probes would be
// pictures the client fails on rather than evidence it can use.
//
// Chosen and encoded under one acquisition of the lock, because the chunk identity is shared state
// and a description built for one lane must not be handed to the other.
        let planned = lock.withLock { () -> (targets: [(lane: Lane, payloads: [Data])], generation: Int) in
            currentConfig = config
            let (carrying, probed) = lanesLocked(fallback: peer)
            let lanes = (probed.map { [$0] } ?? []) + [carrying]
            return (lanes.map { ($0, encode(kind: .videoConfig, payload: json, on: $0)) }, generation)
        }

        for (index, target) in planned.targets.enumerated() {
            guard index == planned.targets.count - 1 else {
                send(target.payloads, on: target.lane) { _ in }
                continue
            }
            send(target.payloads, on: target.lane) { [weak self] _ in
                guard let self else { return }
                let current = lock.withLock { () -> Bool in
                    guard self.generation == planned.generation else { return false }
                    self.sending = false
                    return true
                }
                if current { pump() }
            }
        }
    }

/// Somewhere an encoded frame can go.
///
/// Two cases rather than one, because they are not the same kind of thing: a connection keeps its own
/// order and backpressures, while a datagram path is a series of independent packets that arrive, or
/// do not. What they have in common is the only thing the pump needs from either, a send that
/// eventually reports back.
    private enum Lane {
        case peer(PeerConnection)
        case datagrams(VideoDatagramLane)
    }

    private enum Outgoing {
        case video(EncodedVideoFrame)
        case audioConfig(AudioStreamConfig)
        case audio(EncodedAudioFrame)
    }

    private func pump() {
        let chosen: (payloads: [Data], item: Outgoing, lane: Lane, generation: Int)? = lock.withLock {
            guard !sending, let lane = destinationLocked() else { return nil }

            let item: Outgoing
            if audioConfigOwed, let audioConfig {
                audioConfigOwed = false
                item = .audioConfig(audioConfig)
            } else if let video = pending, pendingAudio != nil, sentAudioLast {
                pending = nil
                sentAudioLast = false
                item = .video(video)
            } else if let audio = pendingAudio {
                pendingAudio = nil
                sentAudioLast = true
                item = .audio(audio)
            } else if let video = pending {
                pending = nil
                sentAudioLast = false
                item = .video(video)
            } else {
                return nil
            }

            sending = true
            return (payloadsLocked(for: item, on: lane), item, lane, generation)
        }
        guard let outgoing = chosen, !outgoing.payloads.isEmpty else {
// An item produced no bytes at all, from a payload that could not be encoded or one too large for the
// chunk header to count. Nothing is in flight, so the pump is disarmed rather than left armed forever
// with the next frame queued behind it.
            if chosen != nil { lock.withLock { sending = false } }
            return
        }

        send(outgoing.payloads, on: outgoing.lane) { [weak self] error in
            guard let self else { return }

            let stillCurrent = lock.withLock { () -> Bool in
// The lane this belongs to has been replaced. Resuming here would drive the new lane's pump from a
// dead one's completion.
                guard self.generation == outgoing.generation else { return false }
                self.sending = false
                if error == nil {
                    switch outgoing.item {
                    case .video(let frame):
                        self._stats.sent += 1
                        self._stats.bytesSent += frame.data.count + EncodedVideoFrame.headerSize
                        if frame.isKeyframe { self._stats.keyframesSent += 1 }
                    case .audio(let frame):
                        self._stats.audioFramesSent += 1
// Counted here rather than at the encoder for the same reason the video bytes are: a frame that was
// offered but never left is not bandwidth.
                        self._stats.audioBytesSent += frame.samples.count + EncodedAudioFrame.headerSize
                    case .audioConfig:
                        break
                    }
                }
                return true
            }

            if let error {
                videoLog.error("video send failed: \(error.localizedDescription, privacy: .public)")
            }
            if stillCurrent { pump() }
        }
    }

/// Sends one item's payloads to one lane, reporting when the last of them is away.
///
/// Every piece but the last goes out without bookkeeping; the pump resumes on the last one. That is
/// what lets the session write a pong between two chunks instead of behind a whole keyframe, which is
/// the entire reason the picture is cut up when it travels the control channel. The order of these
/// writes is the order they are handed over, and both lanes keep it.
    private func send(
        _ payloads: [Data],
        on lane: Lane,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard !payloads.isEmpty else {
            completion(nil)
            return
        }
        switch lane {
        case .peer(let peer):
            var remaining = payloads
            let final = remaining.removeLast()
            for leading in remaining { peer.send(leading) }
            peer.send(final, completion: completion)
        case .datagrams(let lane):
            lane.send(payloads, completion: completion)
        }
    }

/// The lane this pump writes to, for the one the client has asked for.
///
/// The control peer can be missing, a client that asked for the fallback before the host had a control
/// connection to give it, and the session's own peer is then the better answer than nothing: a picture
/// on the lane the client did not ask for beats no picture at all.
    private func destinationLocked() -> Lane? {
        guard transport == .control else { return primaryLaneLocked() }
        if let controlPeer { return .peer(controlPeer) }
        return primaryLaneLocked()
    }

/// Where a description has to go: the lane carrying the picture, and the lane being probed while the
/// picture is somewhere else.
///
/// Both are needed for the same reason a frame needs both: the client decodes what arrives on the lane
/// it asked for, and the probes on the other one are keyframes it must be able to make sense of or
/// they are not evidence of anything.
    private func lanesLocked(fallback peer: PeerConnection) -> (carrying: Lane, probed: Lane?) {
        let primary = primaryLaneLocked() ?? .peer(peer)
        guard transport == .control else { return (primary, nil) }
// The control peer can be missing for a request that arrived before there was one, and the session's
// own peer is then the better answer than none.
        let control = controlPeer.map(Lane.peer) ?? primary
        return (control, Self.sameLane(control, primary) ? nil : primary)
    }

    private static func sameLane(_ one: Lane, _ other: Lane) -> Bool {
        switch (one, other) {
        case (.peer(let a), .peer(let b)): return a === b
        case (.datagrams(let a), .datagrams(let b)): return a === b
        default: return false
        }
    }

/// The transport this session prefers, which is the relay's datagram path when it has one.
///
/// The connection is the answer only when there is no datagram path: on a relayed session it is the
/// stream that already carries input, and sending keyframes down it is the arrangement the datagram
/// path exists to get out of.
    private func primaryLaneLocked() -> Lane? {
        if let datagrams { return .datagrams(datagrams) }
        return peer.map(Lane.peer)
    }

/// Encodes one item into what it becomes on one lane. Call with `lock` held: the chunk identity is
/// shared state, and two frames must not be given the same one.
    private func payloadsLocked(for item: Outgoing, on lane: Lane) -> [Data] {
        switch item {
        case .video(let frame):
            return encode(kind: .videoFrame, payload: frame.encoded(), on: lane)
        case .audioConfig(let config):
            guard let json = try? JSONEncoder().encode(config) else {
                videoLog.error("could not encode the audio config; audio is disabled for this stream")
                return []
            }
            return encode(kind: .audioConfig, payload: json, on: lane)
        case .audio(let frame):
            return encode(kind: .audioFrame, payload: frame.encoded(), on: lane)
        }
    }

/// One payload, as the bytes that go on one lane.
///
/// Three shapes, and each is a rule about the lane rather than a preference: a datagram carries one
/// sealed chunk because a datagram larger than the path's MTU is a picture lost to any fragment; the
/// control channel carries chunks because a whole keyframe in one message is a wall everything else
/// queues behind; and a connection of its own carries the frame whole, because there is nothing to
/// share it with.
    private func encode(kind: MessageKind, payload: Data, on lane: Lane) -> [Data] {
        switch lane {
        case .datagrams(let lane):
            return lane.seal(kind: kind, payload: payload)
        case .peer:
            guard transport == .control else {
                return [FrameEncoder.encode(Frame(kind: kind, payload: payload))]
            }
            chunkFrameID &+= 1
            return VideoChunkEncoder.encode(kind: kind, payload: payload, frameID: chunkFrameID)
                .map(FrameEncoder.encode)
        }
    }

    // MARK: - Audio

/// Retains the current audio format and orders it before every audio frame. Retaining the format is
/// essential for a replacement peer, which joins an already-running capture.
    func sendAudioConfig(_ config: AudioStreamConfig) {
        let shouldPump = lock.withLock { () -> Bool in
            audioConfig = config
            audioConfigOwed = peer != nil
            pendingAudio = nil
            return peer != nil && !sending
        }
        if shouldPump { pump() }
    }

    /// Offers one audio frame to the shared bounded pump. At most one waits; current sound
    /// replaces stale sound when the network is behind instead of accumulating latency.
    func sendAudioFrame(_ frame: EncodedAudioFrame) {
        let shouldPump = lock.withLock { () -> Bool in
            guard peer != nil, audioConfig != nil else { return false }
            if pendingAudio != nil { _stats.audioFramesDropped += 1 }
            pendingAudio = frame
            return !sending
        }
        if shouldPump { pump() }
    }
}
