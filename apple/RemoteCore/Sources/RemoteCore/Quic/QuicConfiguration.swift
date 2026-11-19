import Foundation
import PeeringQuicFFI
import Security

/// The settings both ends of a Peering QUIC connection use, with this device's keychain identity as its TLS identity.
public final class QuicConfiguration: @unchecked Sendable {
    /// Immutable once built; quiche only reads it when a connection is made.
    let pointer: OpaquePointer

    public static let applicationProtocol = "peering/\(ProtocolInfo.version)"

    public enum Failure: Error, LocalizedError {
        case privateKeyUnavailable
        case rejected

        public var errorDescription: String? {
            switch self {
            case .privateKeyUnavailable: "This device's key could not be read from the keychain."
            case .rejected: "This device's key or certificate could not be used for QUIC."
            }
        }
    }

    public init(identity: SelfSignedIdentity) throws {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity.secIdentity, &key) == errSecSuccess, let key,
              let external = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { throw Failure.privateKeyUnavailable }

        let made = identity.certificateDER.withUnsafeBytes { certificate in
            external.withUnsafeBytes { privateKey in
                peering_quic_config_new(
                    certificate.bindMemory(to: UInt8.self).baseAddress, certificate.count,
                    privateKey.bindMemory(to: UInt8.self).baseAddress, privateKey.count
                )
            }
        }
        guard let made else { throw Failure.rejected }
        pointer = made
        configure()
    }

    private func configure() {
        var alpn = Data([UInt8(Self.applicationProtocol.utf8.count)])
        alpn.append(contentsOf: Self.applicationProtocol.utf8)
        alpn.withUnsafeBytes { _ = quiche_config_set_application_protos(pointer, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        // Past the session's own silence limits, which know when the phone said it went to the background: at 15 s QUIC ended every session iOS froze, long before the 180 s a backgrounded phone is allowed.
        quiche_config_set_max_idle_timeout(pointer, UInt64(SessionSilenceLimits.backgrounded * 1000) + 10_000)
        quiche_config_set_max_recv_udp_payload_size(pointer, 1350)
        quiche_config_set_max_send_udp_payload_size(pointer, 1350)
        quiche_config_set_initial_max_data(pointer, 32 * 1024 * 1024)
        quiche_config_set_initial_max_stream_data_bidi_local(pointer, 4 * 1024 * 1024)
        quiche_config_set_initial_max_stream_data_bidi_remote(pointer, 4 * 1024 * 1024)
        quiche_config_set_initial_max_streams_bidi(pointer, 64)
        // Sessions use one unidirectional stream per class each way (``QuicStreamClass``); left at quiche's default of none, every stream frame is refused silently.
        quiche_config_set_initial_max_stream_data_uni(pointer, 4 * 1024 * 1024)
        quiche_config_set_initial_max_streams_uni(pointer, 16)
        quiche_config_set_active_connection_id_limit(pointer, 4)
        quiche_config_enable_dgram(pointer, true, 4096, 4096)
        quiche_config_set_cc_algorithm(pointer, QUICHE_CC_BBR2)
    }

    deinit {
        quiche_config_free(pointer)
    }
}
