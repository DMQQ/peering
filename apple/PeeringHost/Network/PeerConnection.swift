import Foundation
import PeeringKit
import Network
import RemoteCore
import Security

/// One framed connection to a peer.
final class PeerConnection: @unchecked Sendable {
    let connection: NWConnection

    var onFrame: (@Sendable (Frame) -> Void)?
    var onClose: (@Sendable (Error?) -> Void)?
    /// Fires when the bytes handed to this connection and not yet sent pass 4 MB, and again when they fall below 1 MB.
    var onBackPressure: (@Sendable (OutboundBackPressure.Change) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var closed = false
    private var pressure = OutboundBackPressure()  // guarded by lock

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
        send(data) { _ in }
    }

    /// The completion runs when the network stack has taken the bytes, which is what the count of bytes in flight is built on.
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        let size = data.count
        notify(lock.withLock { pressure.queued(size) })
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let self { notify(lock.withLock { pressure.completed(size) }) }
            completion(error)
        })
    }

    var isBackedUp: Bool { lock.withLock { pressure.isBackedUp } }

    private func notify(_ change: OutboundBackPressure.Change?) {
        guard let change else { return }
        onBackPressure?(change)
    }

    func cancel() {
        connection.cancel()
    }

    /// Runs `work` on the queue this connection's callbacks arrive on.
    func onQueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Caps the frame size this connection will buffer, or lifts the cap with nil. A peer that has not proved who it is gets a small one.
    func limitFrames(to limit: UInt32?) {
        lock.withLock { decoder.frameLimit = limit ?? FrameDecoder.maxFrameLength }
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
                    Analytics.failed(error, in: .network, context: ["operation": "decode incoming frames"])
                    // A framing error leaves the byte stream unusable: the next frame boundary
                    // is unknown, so there is no way to resynchronise.
                    finish(error)
                    connection.cancel()
                    return
                }
                for frame in frames { onFrame?(frame) }
            }

            if let error {
                finish(error)
                connection.cancel()
                return
            }
            if isComplete {
                // A clean EOF ends the receive half, but this object owns the whole network
                // resource: cancel explicitly, or Network.framework retains the send half and
                // its protocol stack after observers have been told it is closed.
                finish(nil)
                connection.cancel()
                return
            }
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
    /// anything else means version pinning did not take effect.
    var negotiatedTLSVersion: String {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata
        else { return "None" }

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
private final class CertificateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var certificates: [SecCertificate] = []

    func append(_ certificate: SecCertificate) {
        lock.withLock { certificates.append(certificate) }
    }

    var leaf: SecCertificate? {
        lock.withLock { certificates.first }
    }
}
