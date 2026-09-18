import Foundation
import os

private let knownHostsLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// A server key the user has agreed to.
public struct KnownHost: Codable, Sendable, Equatable {
    public let hostname: String
    public let port: Int
    /// What kind of key it is — `ssh-ed25519`, `ecdsa-sha2-nistp256`, and so on. Stored so the
    /// prompt can name it: a server offering a different *type* of key than last time is a thing
    /// users should be told, and it is not visible from the fingerprint alone.
    public let algorithm: String
    /// The public key exactly as it arrived on the wire: the blob OpenSSH hashes.
    public let publicKey: Data
    public let firstSeen: Date

    public var fingerprint: String { SSHFingerprint.string(of: publicKey) }
}

/// What the app knows about which servers it has spoken to, and whether their key changed.
///
/// The store is in the Keychain, and *not* because a public key is a secret — it is not. It is
/// there because of what it decides: these bytes are what stands between the user's password and
/// whoever is on the other end of the connection. `PinStore`'s own header has the sentence for it:
/// secrecy is not the point, integrity is. A host key that anything able to write a plist could
/// rewrite would make the whole check theatre, and theatre that the user has been *told* is
/// security is worse than nothing at all.
public struct SSHKnownHosts: Sendable {
    public static let service = "pl.dmq.peering.ssh.knownhosts"
    private static let account = "known-hosts"

    /// What to do about the key a server just presented.
    public enum Decision: Equatable {
        /// Never seen this host. The caller asks the user, and records it if they agree.
        case unknown
        /// The same key as last time. Say nothing and connect.
        case match(KnownHost)
        /// A *different* key for a host already known. Never a prompt — see ``SSHKnownHosts``.
        case changed(KnownHost)
    }

    private let backend: SSHSecretBackend

    public init(backend: SSHSecretBackend = KeychainSecretBackend()) {
        self.backend = backend
    }

    public func all() -> [String: KnownHost] {
        guard let data = backend.read(service: Self.service, account: Self.account) else { return [:] }
        do {
            return try JSONDecoder().decode([String: KnownHost].self, from: data)
        } catch {
            // Loudly, and *not* as an empty dictionary. Treating a store that will not decode as
            // "nothing is known" would turn the next connection into a first-sight prompt for a
            // host that is already trusted — which is the one flow this store exists to prevent.
            knownHostsLog.error("could not read known hosts: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    public func host(for endpoint: SSHEndpoint) -> KnownHost? {
        all()[endpoint.key]
    }

    public func decision(for endpoint: SSHEndpoint, publicKey: Data) -> Decision {
        guard let existing = host(for: endpoint) else { return .unknown }
        // Compared byte for byte. A constant-time comparison would be the right instinct for a
        // secret, and this is not one: the value is printed on screen and readable by anyone who
        // can reach the server. What matters is that it is exact.
        return existing.publicKey == publicKey ? .match(existing) : .changed(existing)
    }

    /// Records a key the user has accepted, replacing any earlier one for the same endpoint.
    ///
    /// Replacing is deliberate and only ever reached through the *first-sight* path — a changed key
    /// refuses the connection outright and offers no one-tap acceptance, so the only way an existing
    /// entry is overwritten is after the user has gone to the known-hosts list and forgotten it.
    @discardableResult
    public func record(
        endpoint: SSHEndpoint,
        algorithm: String,
        publicKey: Data,
        now: Date = Date()
    ) -> Bool {
        var hosts = all()
        hosts[endpoint.key] = KnownHost(
            hostname: endpoint.hostname.lowercased(),
            port: endpoint.port,
            algorithm: algorithm,
            publicKey: publicKey,
            firstSeen: now
        )
        return write(hosts)
    }

    @discardableResult
    public func forget(_ endpoint: SSHEndpoint) -> Bool {
        var hosts = all()
        guard hosts.removeValue(forKey: endpoint.key) != nil else { return true }
        return write(hosts)
    }

    @discardableResult
    public func removeAll() -> Bool {
        backend.remove(service: Self.service, account: Self.account)
    }

    private func write(_ hosts: [String: KnownHost]) -> Bool {
        do {
            return backend.write(try JSONEncoder().encode(hosts), service: Self.service, account: Self.account)
        } catch {
            knownHostsLog.error("could not save known hosts: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
