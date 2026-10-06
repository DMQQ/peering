import Foundation
import Network
import Security

public enum TLSConfig {
    public enum Failure: LocalizedError {
        case networkIdentityUnavailable

        public var errorDescription: String? {
            "Could not wrap the local identity for Network.framework."
        }
    }

    // Not Sendable-audited, so capturing `sec_identity_t` in a @Sendable closure warns; the box says why.
    private final class NetworkIdentity: @unchecked Sendable {
        let value: sec_identity_t
        init(_ value: sec_identity_t) { self.value = value }
    }

    public final class ObservedKey: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Data?

        public init() {}

        public var value: Data? { lock.withLock { storage } }
        public func set(_ data: Data) { lock.withLock { storage = data } }
    }

    public static func serverOptions(
        identity: SelfSignedIdentity,
        queue: DispatchQueue
    ) throws -> NWProtocolTLS.Options {
        guard let networkIdentity = sec_identity_create(identity.secIdentity) else {
            throw Failure.networkIdentityUnavailable
        }

        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_local_identity(sec, networkIdentity)

        sec_protocol_options_set_peer_authentication_required(sec, true)

        sec_protocol_options_set_verify_block(sec, { @Sendable _, _, complete in
            complete(true)
        }, queue)

        return options
    }

    public static func clientOptions(
        identity: SelfSignedIdentity?,
        pinnedServerKey: Data?,
        observed: ObservedKey? = nil,
        queue: DispatchQueue
    ) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)

        if let identity, let networkIdentity = sec_identity_create(identity.secIdentity) {
            sec_protocol_options_set_local_identity(sec, networkIdentity)
            let boxed = NetworkIdentity(networkIdentity)
            sec_protocol_options_set_challenge_block(sec, { @Sendable _, complete in
                complete(boxed.value)
            }, queue)
        }

        // @Sendable is mandatory: in a MainActor-default target Swift 6 infers main-actor isolation here, BoringSSL calls it on its own queue, and dispatch_assert_queue traps with SIGTRAP.
        sec_protocol_options_set_verify_block(sec, { @Sendable _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let leaf = chain.first,
                  let presented = SPKI.bytes(of: leaf) else {
                complete(false)
                return
            }

            // Record before the pin decides: ClientSession treats a missing key as fatal, so recording only when unpinned makes a paired Mac unreachable.
            observed?.set(presented)

            if let pinnedServerKey {
                complete(SPKI.matches(pinnedServerKey, presented))
            } else {
                // First pairing: accept so the SAS comparison can run; nothing is trusted until the digits match.
                complete(true)
            }
        }, queue)

        return options
    }
}
