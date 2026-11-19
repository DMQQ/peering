import Foundation

/// The state of every stream between two ends: what is waiting to go, what has arrived, what is owed an acknowledgement. It sends and receives nothing itself. A driver asks it what to put on the carrier now and hands it what arrived, which keeps every rule here testable without a clock or a socket.
public struct StreamMux {
    public enum Carrier: Sendable { case reliable, lossy }

    /// What the streams may have in flight together on a lossy carrier. The picture shares that path, so the control traffic stays a small fraction of it.
    public static let lossyBudgetBytes = ControlPipeSender.lossyWindowBytes
    /// Acknowledgements waiting to go. One per arriving segment, not one per stream: repeats are how the far end learns a segment is lost.
    static let maxPendingAcknowledgements = 512

    private struct Lane {
        var sender = ControlPipeSender()
        var receiver = ControlPipeReceiver()
        var decoder = FrameDecoder()
    }

    private var lanes: [StreamID: Lane] = Dictionary(uniqueKeysWithValues: StreamID.allCases.map { ($0, Lane()) })
    private var owedAcknowledgements: [(stream: StreamID, upTo: UInt64)] = []
    public typealias Completion = @Sendable (Error?) -> Void
    private var completions: [StreamID: [(end: UInt64, run: Completion)]] = [:]

    public init() {}

    /// False for a frame that never travels on a stream: the caller sends it on the control connection as usual.
    /// `completion` runs once the far end has acknowledged the frame (see ``takeCompleted()``): the signal a long transfer paces itself on.
    @discardableResult
    public mutating func enqueue(_ frame: Frame, completion: Completion? = nil) -> Bool {
        guard let stream = StreamRouting.stream(for: frame) else { return false }
        lanes[stream]?.sender.enqueue(FrameEncoder.encode(frame))
        if let completion, let end = lanes[stream]?.sender.enqueuedEnd {
            completions[stream, default: []].append((end, completion))
        }
        return true
    }

    /// The completions whose frames the far end has now acknowledged.
    public mutating func takeCompleted() -> [Completion] {
        var done: [Completion] = []
        for stream in StreamID.allCases {
            guard let acked = lanes[stream]?.sender.ackedOffset else { continue }
            while let first = completions[stream]?.first, first.end <= acked {
                completions[stream]?.removeFirst()
                done.append(first.run)
            }
        }
        return done
    }

    /// Everything still waiting, for the owner to settle when the streams end.
    public mutating func takeAllCompletions() -> [Completion] {
        defer { completions.removeAll() }
        return StreamID.allCases.flatMap { completions[$0]?.map(\.run) ?? [] }
    }

    /// The frames now complete on the stream this segment belongs to, possibly none. Throws when a stream's bytes are not frames, which no repair can fix: the caller ends the session.
    public mutating func receive(_ payload: Data, now: ContinuousClock.Instant) throws -> [Frame] {
        guard let streamFrame = StreamFrame.decode(payload) else { return [] }
        let stream = streamFrame.stream
        guard var lane = lanes[stream] else { return [] }
        defer { lanes[stream] = lane }

        switch streamFrame.pipe {
        case .data(let offset, let bytes):
            let ready = lane.receiver.receive(offset: offset, payload: bytes)
            if owedAcknowledgements.count < Self.maxPendingAcknowledgements {
                owedAcknowledgements.append((stream, lane.receiver.ackPoint))
            }
            guard !ready.isEmpty else { return [] }
            lane.decoder.append(ready)
            var frames: [Frame] = []
            while let frame = try lane.decoder.next() { frames.append(frame) }
            return frames
        case .ack(let upTo):
            lane.sender.acknowledge(upTo: upTo, now: now)
            return []
        }
    }

    /// The payloads of the ``MessageKind/stream`` frames to put on the carrier now: acknowledgements first, then data by priority within the shared budget.
    public mutating func outgoing(now: ContinuousClock.Instant, carrier: Carrier) -> [Data] {
        var out = owedAcknowledgements.map { StreamFrame(stream: $0.stream, pipe: .ack(upTo: $0.upTo)).encoded() }
        owedAcknowledgements.removeAll()

        let ordered = StreamID.allCases.sorted { $0.priority < $1.priority }
        let inFlight = lanes.values.reduce(0) { $0 + $1.sender.inFlightBytes }
        var remaining = max(0, Self.lossyBudgetBytes - inFlight)
        for stream in ordered {
            guard var lane = lanes[stream] else { continue }
            let before = lane.sender.inFlightBytes
            let frames = lane.sender.frames(now: now, carrier: carrier == .lossy ? .lossy : .reliable, window: before + remaining)
            remaining = max(0, remaining - max(0, lane.sender.inFlightBytes - before))
            out.append(contentsOf: frames.map { StreamFrame(stream: stream, pipe: $0).encoded() })
            lanes[stream] = lane
        }
        return out
    }

    /// The path the bytes travel changed: whatever was in flight on the old one may be lost.
    public mutating func carrierChanged() {
        for stream in StreamID.allCases { lanes[stream]?.sender.carrierChanged() }
    }

    /// Timeouts in a row on the worst stream, which is how a driver notices a lane that stopped working.
    public var consecutiveTimeouts: Int {
        lanes.values.map(\.sender.consecutiveTimeouts).max() ?? 0
    }

    public var hasUnacknowledged: Bool { lanes.values.contains { $0.sender.hasUnacknowledged } }

    public func bufferedBytes(of stream: StreamID) -> Int { lanes[stream]?.sender.bufferedBytes ?? 0 }

    /// When a lossy carrier should next be given a chance to resend, or nil with nothing outstanding.
    public func retransmitDeadline() -> ContinuousClock.Instant? {
        lanes.values.compactMap { $0.sender.retransmitDeadline() }.min()
    }

    public var hasWork: Bool {
        !owedAcknowledgements.isEmpty || lanes.values.contains { $0.sender.bufferedBytes > 0 && $0.sender.inFlightBytes < $0.sender.bufferedBytes }
    }
}
