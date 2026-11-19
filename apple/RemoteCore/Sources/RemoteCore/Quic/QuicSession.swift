import Foundation
import Security

/// Peering's frame protocol over one QUIC connection: each ``Frame`` goes on its class's stream (``QuicStreamClass``), or as datagrams for picture, sound and direct input. Sans-IO like ``QuicConnection``: the owner moves packets and calls ``takeFrames()`` after each batch.
///
/// `@unchecked Sendable`: its own state is guarded by `lock`, taken before the connection's and never the other way.
public final class QuicSession: @unchecked Sendable {
    public let connection: QuicConnection
    public let isClient: Bool
    private let lock = NSLock()
    private var decoders: [UInt64: FrameDecoder] = [:]
    /// Bytes quiche has not taken yet (flow control, or the congestion window), in order.
    private var unsent: [UInt64: Data] = [:]
    private var reassemblers = ChunkReassemblers()
    private var chunkFrameID: UInt32 = 0
    private var sparesIssued = false
    private var prioritised: Set<UInt64> = []
    /// Per stream, bytes ever queued and bytes quiche has taken; a frame's completion runs once `taken` passes the end of it.
    private var queuedTotal: [UInt64: UInt64] = [:]
    private var takenTotal: [UInt64: UInt64] = [:]
    private var waiting: [UInt64: [(end: UInt64, completion: @Sendable (Error?) -> Void)]] = [:]

    public typealias Completion = @Sendable (Error?) -> Void
    private var datagramWaiting: [Completion] = []

    /// Parity chunks per this many picture chunks; the sender lowers it as measured loss rises.
    public var parityGroup: Int {
        get { lock.withLock { _parityGroup } }
        set { lock.withLock { _parityGroup = newValue } }
    }
    private var _parityGroup = VideoChunk.parityGroupSize

    public init(connection: QuicConnection, isClient: Bool) {
        self.connection = connection
        self.isClient = isClient
    }

    // MARK: - Sending

    /// Queues a frame. False only when a datagram could not be queued (it is dropped, as a lost one would be). `completion` runs once quiche has taken the whole frame into its send buffer, which is what a sender pacing a long transfer waits on; a datagram's runs at once.
    @discardableResult
    public func send(_ frame: Frame, completion: Completion? = nil) -> Bool {
        guard let streamClass = QuicStreamClass.of(frame) else {
            let queued = sendAsDatagrams(frame)
            guard let completion else { return queued }
            // A picture's sender waits on this before handing over the next one, so a link that cannot keep up holds one picture back instead of a growing queue of them.
            let runNow = lock.withLock { () -> Bool in
                guard connection.datagramBacklogBytes > datagramBacklogLimitLocked() else { return true }
                datagramWaiting.append(completion)
                return false
            }
            if runNow { completion(nil) }
            return queued
        }
        let stream = streamClass.streamID(sentByClient: isClient)
        let encoded = FrameEncoder.encode(frame)
        let due = lock.withLock { () -> [Completion] in
            unsent[stream, default: Data()].append(encoded)
            let end = queuedTotal[stream, default: 0] + UInt64(encoded.count)
            queuedTotal[stream] = end
            if let completion { waiting[stream, default: []].append((end, completion)) }
            let due = writeUnsentLocked(stream)
            // After the write: quiche refuses a priority for a stream its first write has not created.
            if !prioritised.contains(stream),
               connection.setPriority(ofStream: stream, urgency: streamClass.urgency, incremental: streamClass.isIncremental) {
                prioritised.insert(stream)
            }
            return due
        }
        for completion in due { completion(nil) }
        return true
    }

    /// Retries what quiche held back, most urgent stream first: it takes new stream data only up to what the congestion window allows, so whichever stream asks first gets the room.
    public func writeUnsent() {
        let due = lock.withLock { () -> [Completion] in
            let byUrgency = unsent.keys.sorted {
                (QuicStreamClass(streamID: $0)?.urgency ?? .max) < (QuicStreamClass(streamID: $1)?.urgency ?? .max)
            }
            return byUrgency.flatMap { writeUnsentLocked($0) }
        }
        for completion in due { completion(nil) }
    }

    /// Runs the datagram senders' completions once quiche's datagram queue is short again. Call after packets have gone out.
    public func releaseDatagramWaiters() {
        let due = lock.withLock { () -> [Completion] in
            guard !datagramWaiting.isEmpty, connection.datagramBacklogBytes <= datagramBacklogLimitLocked() else { return [] }
            defer { datagramWaiting = [] }
            return datagramWaiting
        }
        for completion in due { completion(nil) }
    }

    /// About 40 ms of the path's measured capacity, so the wait tracks the link rather than a constant.
    private func datagramBacklogLimitLocked() -> Int {
        let bandwidth = connection.pathSample?.bandwidthBytesPerSecond ?? 0
        return min(2_000_000, max(32_768, Int(bandwidth / 25)))
    }

    /// Bytes queued on streams that quiche has not taken yet: the measure of a sender running ahead of the path.
    public var unsentBytes: Int { lock.withLock { unsent.values.reduce(0) { $0 + $1.count } } }

    /// Ends every waiting completion, for a connection that will never send them.
    public func failWaiting(_ error: Error) {
        let all = lock.withLock { () -> [Completion] in
            defer { waiting = [:]; unsent = [:]; datagramWaiting = [] }
            return waiting.values.flatMap { $0.map(\.completion) } + datagramWaiting
        }
        for completion in all { completion(error) }
    }

    /// Returns the completions now due; the caller runs them after releasing the lock.
    private func writeUnsentLocked(_ stream: UInt64) -> [Completion] {
        guard let pending = unsent[stream], !pending.isEmpty else { return [] }
        let taken = connection.send(pending, onStream: stream)
        unsent[stream] = taken >= pending.count ? nil : Data(pending.dropFirst(taken))
        let total = takenTotal[stream, default: 0] + UInt64(taken)
        takenTotal[stream] = total
        guard let queue = waiting[stream] else { return [] }
        let firstLater = queue.firstIndex { $0.end > total } ?? queue.endIndex
        waiting[stream] = Array(queue[firstLater...])
        return queue[..<firstLater].map(\.completion)
    }

    private func sendAsDatagrams(_ frame: Frame) -> Bool {
        let limit = connection.maxDatagramPayload ?? 1200
        let whole = FrameEncoder.encode(frame)
        if whole.count <= limit { return connection.sendDatagram(whole) }
        let pieces = lock.withLock { () -> [Frame] in
            chunkFrameID &+= 1
            // A chunk's own header is 13 bytes and the frame around it 5; the rest of the datagram is its body.
            return VideoChunkEncoder.encodeWithParity(kind: frame.kind, payload: frame.payload, frameID: chunkFrameID, chunkSize: limit - 5 - 13, group: _parityGroup)
        }
        var allQueued = true
        for piece in pieces where !connection.sendDatagram(FrameEncoder.encode(piece)) { allQueued = false }
        return allQueued
    }

    // MARK: - Receiving

    /// Every whole frame that arrived since the last call, streams first. Throws when a stream carries bytes that are not frames, which means the peer is not speaking this protocol.
    public func takeFrames() throws -> [Frame] {
        issueSparesOnceEstablished()
        var frames: [Frame] = []
        for read in connection.readStreams() where QuicStreamClass(streamID: read.stream) != nil {
            try lock.withLock {
                var decoder = decoders[read.stream] ?? FrameDecoder()
                defer { decoders[read.stream] = decoder }
                decoder.append(read.bytes)
                while let frame = try decoder.next() { frames.append(frame) }
            }
        }
        for datagram in connection.readDatagrams() {
            var decoder = FrameDecoder()
            decoder.append(datagram)
            // A datagram that is not a frame is dropped: it cannot be repaired, and nothing waits on it.
            guard let frame = try? decoder.next() else { continue }
            if frame.kind == .videoChunk {
                let whole = lock.withLock { try? reassemblers.ingest(frame) }
                if let whole { frames.append(whole) }
            } else {
                frames.append(frame)
            }
        }
        return frames
    }

    private func issueSparesOnceEstablished() {
        let due = lock.withLock { () -> Bool in
            guard !sparesIssued, connection.isEstablished else { return false }
            sparesIssued = true
            return true
        }
        if due { connection.issueSpareConnectionIDs() }
    }

    // MARK: - Identity

    /// The peer's public key in the form pins are stored in, once the handshake has shown its certificate.
    public var peerPublicKey: Data? {
        guard let der = connection.peerCertificate,
              let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else { return nil }
        return SPKI.bytes(of: certificate)
    }
}
