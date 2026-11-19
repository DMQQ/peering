import Foundation
import os

private let linkLog = Logger(subsystem: "pl.dmq.peering", category: "quic")

/// A Peering session's whole transport over QUIC, shaped like the framed TLS connections it replaces: frames in through ``send(_:)``, frames out through ``onFrame``, the peer's key for the pin check, and one ``onClose``.
///
/// `@unchecked Sendable`: callbacks are guarded by `lock`; the carrier and session are themselves safe to call from any thread.
public final class QuicFrameLink: @unchecked Sendable {
    /// What moves this link's packets: a socket of its own (``QuicEndpoint``) or a share of a listener's (``QuicListener``).
    struct Carrier: Sendable {
        let queue: DispatchQueue
        /// Sends what the connection has queued; runs on `queue`.
        let flush: @Sendable () -> Void
        /// Stops carrying this link's packets; runs on `queue`.
        let cancel: @Sendable () -> Void
    }

    private let carrier: Carrier
    /// Owned when the link has a socket of its own, so the socket lives as long as the link.
    private let endpoint: QuicEndpoint?
    private let lock = NSLock()
    private var session: QuicSession?
    private var _onFrame: (@Sendable (Frame) -> Void)?
    private var _onClose: (@Sendable (String?) -> Void)?
    private var _onEstablished: (@Sendable () -> Void)?
    private var announcedEstablished = false
    /// Frames already split from bytes handed to ``send(bytes:completion:)``, which may cut a frame in two.
    private var outgoingDecoder = FrameDecoder()
    /// Frames sent before the first packet created the session; sent the moment it exists.
    private var early: [(frame: Frame, completion: QuicSession.Completion?)] = []

    public var onFrame: (@Sendable (Frame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// The reason, when the peer or quiche gave one. Called once.
    public var onClose: (@Sendable (String?) -> Void)? {
        get { lock.withLock { _onClose } }
        set { lock.withLock { _onClose = newValue } }
    }

    /// Once the handshake is done and the peer's certificate is known.
    public var onEstablished: (@Sendable () -> Void)? {
        get { lock.withLock { _onEstablished } }
        set { lock.withLock { _onEstablished = newValue } }
    }

    /// What a waiting send is told when the connection ends before quiche took its bytes.
    public struct Closed: Error {}

    /// Where the peer's first packet came from, for a link a listener accepted. Admission limits count attempts per address.
    public let peerAddress: QuicAddress?

    init(carrier: Carrier, peerAddress: QuicAddress) {
        self.carrier = carrier
        self.peerAddress = peerAddress
        endpoint = nil
    }

    private init(endpoint: QuicEndpoint) {
        self.endpoint = endpoint
        peerAddress = nil
        carrier = Carrier(queue: endpoint.queue, flush: { [weak endpoint] in endpoint?.flush() }, cancel: { [weak endpoint] in endpoint?.cancel() })
        endpoint.onActivity = { [weak self] connection in self?.activity(on: connection) }
        endpoint.onFlushed = { [weak self] in self?.afterFlush() }
        endpoint.onClosed = { [weak self] _ in self?.closed() }
    }

    /// The phone's end: dials `peer`, which is the relay when `relay` is given.
    public static func dial(_ peer: QuicAddress, relay: QuicEndpoint.RelayRoute?, configuration: QuicConfiguration, label: String) throws -> QuicFrameLink {
        let endpoint = try QuicEndpoint.connect(to: peer, configuration: configuration, queue: DispatchQueue(label: label), relay: relay)
        return QuicFrameLink(endpoint: endpoint)
    }

    /// The Mac's end: waits for the phone behind the relay, or on `port` when `relay` is nil.
    public static func listen(port: UInt16, relay: QuicEndpoint.RelayRoute?, configuration: QuicConfiguration, label: String) throws -> QuicFrameLink {
        let endpoint = try QuicEndpoint.listen(port: port, configuration: configuration, queue: DispatchQueue(label: label), relay: relay)
        return QuicFrameLink(endpoint: endpoint)
    }

    // MARK: - Sending

    /// `completion` runs once quiche has taken the frame (see ``QuicSession/send(_:completion:)``), or with an error if the link closes first.
    public func send(_ frame: Frame, completion: QuicSession.Completion? = nil) {
        let session = lock.withLock { () -> QuicSession? in
            if session == nil { early.append((frame, completion)) }
            return session
        }
        guard let session else { return }
        session.send(frame, completion: completion)
        carrier.queue.async { [carrier] in carrier.flush() }
    }

    /// Bytes already framed by ``FrameEncoder``, as the picture's sender produces them: split back into frames so each goes where its kind belongs. `completion` runs once the last whole frame in them has been taken.
    public func send(bytes: Data, completion: QuicSession.Completion? = nil) {
        let frames = lock.withLock { () -> [Frame] in
            outgoingDecoder.append(bytes)
            var frames: [Frame] = []
            while let frame = try? outgoingDecoder.next() { frames.append(frame) }
            return frames
        }
        guard !frames.isEmpty else {
            completion?(nil)
            return
        }
        for (index, frame) in frames.enumerated() {
            send(frame, completion: index == frames.count - 1 ? completion : nil)
        }
    }

    /// Bytes queued on streams that quiche has not taken yet.
    public var unsentBytes: Int { lock.withLock { session }?.unsentBytes ?? 0 }

    public var peerPublicKey: Data? { lock.withLock { session }?.peerPublicKey }

    public var isEstablished: Bool { lock.withLock { session }?.connection.isEstablished ?? false }

    public func close(reason: String = "closed") {
        if let session = lock.withLock({ session }) {
            session.connection.close(reason: reason)
            carrier.queue.async { [carrier] in carrier.flush() }
        }
        carrier.queue.asyncAfter(deadline: .now() + 0.2) { [carrier] in carrier.cancel() }
    }

    /// What quiche measures about the path, and the datagrams it has not sent yet: what the picture's bitrate is set from.
    public var pathSample: QuicConnection.PathSample? { lock.withLock { session }?.connection.pathSample }
    public var datagramBacklogBytes: Int { lock.withLock { session }?.connection.datagramBacklogBytes ?? 0 }

    // MARK: - On the carrier's queue

    /// After the carrier has sent what was queued.
    func afterFlush() {
        lock.withLock { session }?.releaseDatagramWaiters()
    }

    func activity(on connection: QuicConnection) {
        let (session, established, held) = lock.withLock { () -> (QuicSession, (@Sendable () -> Void)?, [(frame: Frame, completion: QuicSession.Completion?)]) in
            let session = self.session ?? QuicSession(connection: connection, isClient: !connection.isServer)
            self.session = session
            let held = early
            early = []
            var announce: (@Sendable () -> Void)?
            if connection.isEstablished, !announcedEstablished, _onEstablished != nil {
                announcedEstablished = true
                announce = _onEstablished
            }
            return (session, announce, held)
        }
        for item in held { session.send(item.frame, completion: item.completion) }
        established?()
        do {
            let frames = try session.takeFrames()
            let handler = onFrame
            for frame in frames { handler?(frame) }
        } catch {
            linkLog.error("a stream carried bytes that are not frames: \(String(describing: error), privacy: .public)")
            session.connection.close(reason: "unreadable stream")
        }
        session.writeUnsent()
    }

    func closed() {
        let (handler, session, held) = lock.withLock { () -> ((@Sendable (String?) -> Void)?, QuicSession?, [(frame: Frame, completion: QuicSession.Completion?)]) in
            let handler = _onClose
            let held = early
            early = []
            _onClose = nil
            _onFrame = nil
            _onEstablished = nil
            return (handler, session, held)
        }
        let error = QuicFrameLink.Closed()
        session?.failWaiting(error)
        for item in held { item.completion?(error) }
        carrier.cancel()
        handler?(nil)
    }
}
