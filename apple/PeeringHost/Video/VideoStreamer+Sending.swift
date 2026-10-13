import Foundation
import RemoteCore
import os

extension VideoStreamer {
    func sendConfig(_ config: VideoStreamConfig, to peer: PeerConnection) {
        guard let json = try? JSONEncoder().encode(config) else {
            streamerLog.error("could not encode the video config; the client will see no video")
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
    enum Lane {
        case peer(PeerConnection)
        case datagrams(VideoDatagramLane)
    }

    enum Outgoing {
        case video(EncodedVideoFrame)
        case audioConfig(AudioStreamConfig)
        case audio(EncodedAudioFrame)
    }

    func pump() {
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
                streamerLog.error("video send failed: \(error.localizedDescription, privacy: .public)")
            }
            if stillCurrent { pump() }
        }
    }

/// Sends one item's payloads to one lane, reporting when the last of them is away.
    func send(
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

    func destinationLocked() -> Lane? {
        guard transport == .control else { return primaryLaneLocked() }
        if let controlPeer { return .peer(controlPeer) }
        return primaryLaneLocked()
    }

/// Where a description has to go: the lane carrying the picture, and the lane being probed while the
/// picture is somewhere else.
    func lanesLocked(fallback peer: PeerConnection) -> (carrying: Lane, probed: Lane?) {
        let primary = primaryLaneLocked() ?? .peer(peer)
        guard transport == .control else { return (primary, nil) }
        let control = controlPeer.map(Lane.peer) ?? primary
        return (control, Self.sameLane(control, primary) ? nil : primary)
    }

    static func sameLane(_ one: Lane, _ other: Lane) -> Bool {
        switch (one, other) {
        case (.peer(let a), .peer(let b)): return a === b
        case (.datagrams(let a), .datagrams(let b)): return a === b
        default: return false
        }
    }

/// The transport this session prefers, which is the relay's datagram path when it has one.
    func primaryLaneLocked() -> Lane? {
        if let datagrams { return .datagrams(datagrams) }
        return peer.map(Lane.peer)
    }

/// Encodes one item into what it becomes on one lane. Call with `lock` held: the chunk identity is
/// shared state, and two frames must not be given the same one.
    func payloadsLocked(for item: Outgoing, on lane: Lane) -> [Data] {
        switch item {
        case .video(let frame):
            return encode(kind: .videoFrame, payload: frame.encoded(), on: lane)
        case .audioConfig(let config):
            guard let json = try? JSONEncoder().encode(config) else {
                streamerLog.error("could not encode the audio config; audio is disabled for this stream")
                return []
            }
            return encode(kind: .audioConfig, payload: json, on: lane)
        case .audio(let frame):
            return encode(kind: .audioFrame, payload: frame.encoded(), on: lane)
        }
    }

/// One payload, as the bytes that go on one lane.
    func encode(kind: MessageKind, payload: Data, on lane: Lane) -> [Data] {
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
}
