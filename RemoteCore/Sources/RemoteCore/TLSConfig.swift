import Foundation
import Network
import Security

/// TLS setup for both roles.
///
/// Both directions are TLS 1.3 with a pinned peer key. The client pins the host so it
/// cannot be impersonated. The host requires a client certificate so that a client has a
/// stable identity from its very first byte — without that there would be nothing to pin,
/// and "remember this device" would have no meaning.
public enum TLSConfig {
    public enum Failure: LocalizedError {
        case networkIdentityUnavailable

        public var errorDescription: String? {
            "Could not wrap the local identity for Network.framework."
        }
    }

    /// Captures the peer key observed during a first-pairing handshake.
    ///
    /// The verify block is `@Sendable` and BoringSSL invokes it on its own dispatch queue,
    /// so anything it observes has to cross a concurrency boundary. A lock is the honest
    /// tool for a value written once and read later.
    /// Carries the local identity into the challenge block.
    ///
    /// `sec_identity_t` is an immutable CoreFoundation object and safe to share across
    /// threads, but the Security module is not Sendable-audited, so capturing it directly
    /// in a `@Sendable` closure warns. This box states the reasoning explicitly instead of
    /// suppressing the diagnostic with `@preconcurrency`, which would also hide any future
    /// warning the module genuinely deserves.
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

        // Servers default to false. Without this the client is never asked for a
        // certificate, every connection is anonymous, and there is nothing stable to pin.
        sec_protocol_options_set_peer_authentication_required(sec, true)

        // The client's certificate is self-signed, so system trust evaluation would reject
        // it every time. Authenticity here comes from the pairing exchange rather than from
        // a CA, so accept the chain at this layer and let the session decide authorization
        // once it knows which client ID is actually being claimed.
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
            // Invoked when the server requests a client certificate. Supplying it here is
            // what makes this connection mutual TLS rather than one-way.
            sec_protocol_options_set_challenge_block(sec, { @Sendable _, complete in
                complete(boxed.value)
            }, queue)
        }

        // @Sendable is mandatory, not stylistic. In a MainActor-default target Swift 6
        // would otherwise infer main-actor isolation for this closure, while BoringSSL
        // calls it on its own dispatch queue — the mismatch trips dispatch_assert_queue
        // and traps with SIGTRAP before any of our code runs.
        sec_protocol_options_set_verify_block(sec, { @Sendable _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let leaf = chain.first,
                  let presented = SPKI.bytes(of: leaf) else {
                complete(false)
                return
            }

            if let pinnedServerKey {
                complete(SPKI.matches(pinnedServerKey, presented))
            } else {
                // First pairing: no pin exists yet, and refusing here would make pairing
                // impossible. Accept so the SAS comparison can run, and record what was
                // seen so the pairing layer can bind it into the transcript. Nothing is
                // trusted until the user confirms the digits match.
                observed?.set(presented)
                complete(true)
            }
        }, queue)

        return options
    }
}
