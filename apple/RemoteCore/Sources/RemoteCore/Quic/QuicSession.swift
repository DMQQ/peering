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

    /// Queues a frame. False only when a datagram could not be queued (it is dropped, as a lost one would be).
    @discardableResult
    public func send(_ frame: Frame) -> Bool {
        guard let streamClass = QuicStreamClass.of(frame) else { return sendAsDatagrams(frame) }
        let stream = streamClass.streamID(sentByClient: isClient)
        lock.withLock {
            unsent[stream, default: Data()].append(FrameEncoder.encode(frame))
            writeUnsentLocked(stream)
            // After the write: quiche refuses a priority for a stream its first write has not created.
            if !prioritised.contains(stream),
               connection.setPriority(ofStream: stream, urgency: streamClass.urgency, incremental: streamClass.isIncremental) {
                prioritised.insert(stream)
            }
        }
        return true
    }

    /// Retries what quiche held back, most urgent stream first: it takes new stream data only up to what the congestion window allows, so whichever stream asks first gets the room.
    public func writeUnsent() {
        lock.withLock {
            let byUrgency = unsent.keys.sorted {
                (QuicStreamClass(streamID: $0)?.urgency ?? .max) < (QuicStreamClass(streamID: $1)?.urgency ?? .max)
            }
            for stream in byUrgency { writeUnsentLocked(stream) }
        }
    }

    private func writeUnsentLocked(_ stream: UInt64) {
        guard let pending = unsent[stream], !pending.isEmpty else { return }
        let taken = connection.send(pending, onStream: stream)
        unsent[stream] = taken >= pending.count ? nil : Data(pending.dropFirst(taken))
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
