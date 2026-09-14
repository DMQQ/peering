import Foundation
import Network
import RemoteCore
import Security

/// One framed connection to a peer.
///
/// Owns the receive loop and the ``FrameDecoder``. Everything above this layer deals in
/// whole ``Frame`` values and never sees a partial read, which is the point: TCP delivers
/// an arbitrary byte window, so frames arrive split, fused, or several at a time and the
/// framing layer is the only place that has to care.
final class PeerConnection: @unchecked Sendable {
    let connection: NWConnection

    /// Delivered on the connection's queue. Set these before calling ``start()``.
    var onFrame: (@Sendable (Frame) -> Void)?
    var onClose: (@Sendable (Error?) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                receiveNext()
            case .failed(let error):
                finish(error)
            case .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ frame: Frame) {
        send(FrameEncoder.encode(frame))
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Sends and reports acceptance, for the video path where dropping beats queueing.
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                let frames: [Frame]
                do {
                    frames = try appendAndDrain(data)
                } catch {
                    // A framing error leaves the byte stream unusable: we no longer know
                    // where the next frame begins, so there is no way to resynchronise.
                    finish(error)
                    connection.cancel()
                    return
                }
                for frame in frames { onFrame?(frame) }
            }

            if let error { finish(error); return }
            if isComplete { finish(nil); return }
            receiveNext()
        }
    }

    private func appendAndDrain(_ data: Data) throws -> [Frame] {
        lock.lock()
        defer { lock.unlock() }
        decoder.append(data)
        var frames: [Frame] = []
        while let frame = try decoder.next() { frames.append(frame) }
        return frames
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        onClose?(error)
    }

    /// The peer's leaf-certificate public key, or `nil` before the handshake completes.
    ///
    /// This is the value the host pins. It comes from the TLS layer rather than from the
    /// handshake messages on purpose — a peer that could simply *claim* a public key would
    /// make pinning meaningless.
    var peerPublicKey: Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata
        else { return nil }

        let collector = CertificateCollector()
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            collector.append(sec_certificate_copy_ref(certificate).takeRetainedValue())
        }
        return collector.leaf.flatMap { SPKI.bytes(of: $0) }
    }

    /// Negotiated TLS version, for the diagnostics panel. "TLS 1.3" is the expected value;
    /// anything else means the version pinning did not take effect.
    var negotiatedTLSVersion: String {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata
        else { return "—" }

        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(
            metadata.securityProtocolMetadata
        )
        switch version {
        case .TLSv13: return "TLS 1.3"
        case .TLSv12: return "TLS 1.2"
        default: return "unknown"
        }
    }
}

/// Accumulates certificates from `sec_protocol_metadata_access_peer_certificate_chain`.
///
/// That API hands each certificate to a block, and the block may be `@Sendable`, so a
/// plain captured `var` is not safe to write from it. A lock-protected box keeps the
/// accumulator honest regardless of how the SDK imports the callback.
private final class CertificateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var certificates: [SecCertificate] = []

    func append(_ certificate: SecCertificate) {
        lock.withLock { certificates.append(certificate) }
    }

    /// The leaf is delivered first.
    var leaf: SecCertificate? {
        lock.withLock { certificates.first }
    }
}
