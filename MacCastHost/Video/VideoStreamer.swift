import Foundation
import RemoteCore
import os

private let videoLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

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

    private let lock = NSLock()
    private var peer: PeerConnection?
    private var pending: EncodedVideoFrame?
    private var pendingAudio: EncodedAudioFrame?
    private var audioConfig: AudioStreamConfig?
    private var audioConfigOwed = false
    private var sentAudioLast = true
    private var sending = false
    private var _stats = Stats()

    private var transport: VideoTransport = .primary
    private var controlPeer: PeerConnection?

    private var datagrams: VideoDatagramLane?

    var isDirectOpen: Bool { lock.withLock { datagrams }?.isDirectOpen ?? false }

/// The description of the stream being sent, held so it can be re-sent.
    private var currentConfig: VideoStreamConfig?
/// The most recent recovery point for the current stream. ScreenCaptureKit emits no new picture for a
/// completely still desktop, so merely asking the encoder for a keyframe can wait forever. A newly
/// attached client gets this one immediately, while the encoder is still asked for a fresh keyframe
/// before any later delta is allowed through.
    private var latestKeyframe = DeferredVideoKeyframe()

    private var chunkFrameID: UInt32 = 0

    private var lastFrameAt: TimeInterval = 0
    private var lastKeyframeAt: TimeInterval = 0
    private var lastProbeAt: TimeInterval = 0
    private var probeTimer: DispatchSourceTimer?

/// How often the transport the session came from is offered a keyframe while video is on the control
/// channel.
    private static let probeInterval: TimeInterval = 4

    private static let probeQueue = DispatchQueue(label: "pl.dmq.peering.host.video.probe", qos: .utility)

/// Whether the attached client is owed a keyframe before anything else reaches it.
    private var awaitingKeyframe = false

    private var generation = 0

    /// Asks the capture pipeline for an immediate keyframe.
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
            videoLog.notice("video is on the control channel; the preferred transport is probed with keyframes")
            return true
        }

        if transport == .control {
            lock.withLock {
                self.transport = .primary
                self.controlPeer = nil
            }
            videoLog.notice("the control channel was asked for before the stream had a description")
            return false
        }

        requestKeyframe()
        videoLog.notice("video is back on the transport the client prefers")
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
            videoLog.notice("the relay's video datagram path was taken away")
            return false
        }
        lane?.start()
        requestKeyframe()
        videoLog.notice("video is on the relay's datagram path")
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
            videoLog.notice("""
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
        videoLog.notice("video config updated · \(config.sourceID, privacy: .public) \(config.pixelWidth)×\(config.pixelHeight)")
    }

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

    // MARK: - Probes

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
            if chosen != nil { lock.withLock { sending = false } }
            return
        }

        send(outgoing.payloads, on: outgoing.lane) { [weak self] error in
            guard let self else { return }

            let stillCurrent = lock.withLock { () -> Bool in
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

    private func destinationLocked() -> Lane? {
        guard transport == .control else { return primaryLaneLocked() }
        if let controlPeer { return .peer(controlPeer) }
        return primaryLaneLocked()
    }

/// Where a description has to go: the lane carrying the picture, and the lane being probed while the
/// picture is somewhere else.
    private func lanesLocked(fallback peer: PeerConnection) -> (carrying: Lane, probed: Lane?) {
        let primary = primaryLaneLocked() ?? .peer(peer)
        guard transport == .control else { return (primary, nil) }
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

    func sendAudioConfig(_ config: AudioStreamConfig) {
        let shouldPump = lock.withLock { () -> Bool in
            audioConfig = config
            audioConfigOwed = peer != nil
            pendingAudio = nil
            return peer != nil && !sending
        }
        if shouldPump { pump() }
    }

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
