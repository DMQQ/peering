import Foundation
import Network
import Security

/// TLS setup for both roles. Both directions are TLS 1.3 with a pinned peer key: the client pins
/// the host so it cannot be impersonated, and the host requires a client certificate so a client
/// has a stable identity from its first byte, without which there is nothing to pin.
public enum TLSConfig {
    public enum Failure: LocalizedError {
        case networkIdentityUnavailable

        public var errorDescription: String? {
            "Could not wrap the local identity for Network.framework."
        }
    }

    /// Captures the peer key observed during a first-pairing handshake. The verify block is
    /// `@Sendable` and BoringSSL runs it on its own queue, so a lock is needed for a value written
    /// once and read later.
    /// Carries the local identity into the challenge block. `sec_identity_t` is safe to share, but
    /// Security is not Sendable-audited, so capturing it in a `@Sendable` closure warns; the box
    /// states why rather than suppressing the diagnostic.
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

    /// Server options. Throws rather than silently continuing without an identity, since a
    /// listener with no certificate would accept connections it cannot authenticate.
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

        // Servers default to false. Without this the client is never asked for a certificate and
        // there is nothing stable to pin.
        sec_protocol_options_set_peer_authentication_required(sec, true)

        // The client's certificate is self-signed, so system trust evaluation would reject it every
        // time. Authenticity comes from the pairing exchange rather than from a CA, so accept the
        // chain here and let the session decide authorization once it knows the claimed client ID.
        sec_protocol_options_set_verify_block(sec, { @Sendable _, _, complete in
            complete(true)
        }, queue)

        return options
    }

    /// Client options. A non-nil `pinnedServerKey` makes the pin mandatory; nil means this
    /// is a first pairing, where security comes from the SAS comparison instead.
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
            // Invoked when the server requests a client certificate; supplying it is what makes
            // this connection mutual TLS rather than one-way.
            sec_protocol_options_set_challenge_block(sec, { @Sendable _, complete in
                complete(boxed.value)
            }, queue)
        }

        // @Sendable is mandatory, not stylistic: in a MainActor-default target Swift 6 would
        // otherwise infer main-actor isolation for this closure, while BoringSSL calls it on its
        // own dispatch queue, and the mismatch trips dispatch_assert_queue and traps with SIGTRAP.
        sec_protocol_options_set_verify_block(sec, { @Sendable _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let leaf = chain.first,
                  let presented = SPKI.bytes(of: leaf) else {
                complete(false)
                return
            }

            // Recorded unconditionally, before the pin decides anything: this block answers two
            // separate questions, may this connection proceed and which key did the server present.
            // `ClientSession` treats a missing key as fatal, so recording only on the unpinned path
            // would make an already-paired Mac unreachable.
            observed?.set(presented)

            if let pinnedServerKey {
                complete(SPKI.matches(pinnedServerKey, presented))
            } else {
                // First pairing: no pin exists yet, and refusing here would make pairing
                // impossible. Accept so the SAS comparison can run, and let the pairing layer bind
                // the recorded key into the transcript. Nothing is trusted until the digits match.
                complete(true)
            }
        }, queue)

        return options
    }
}
