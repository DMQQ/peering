import Foundation
import os

private let knownHostsLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

public struct KnownHost: Codable, Sendable, Equatable {
    public let hostname: String
    public let port: Int
    /// The key type (`ssh-ed25519`, ...), stored so the prompt can name it: a different type than last time is not visible from the fingerprint alone.
    public let algorithm: String
    public let publicKey: Data
    public let firstSeen: Date

    public var fingerprint: String { SSHFingerprint.string(of: publicKey) }
}

/// Kept in the Keychain for integrity, not secrecy: a host key that anything able to write a plist could rewrite would make the check theatre.
public struct SSHKnownHosts: Sendable {
    public static let service = "pl.dmq.peering.ssh.knownhosts"
    private static let account = "known-hosts"

    public enum Decision: Equatable {
        case unknown
        case match(KnownHost)
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
            // Loudly, and not as an empty dictionary: that would turn the next connection into a first-sight prompt for a host already trusted.
            knownHostsLog.error("could not read known hosts: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    public func host(for endpoint: SSHEndpoint) -> KnownHost? {
        all()[endpoint.key]
    }

    public func decision(for endpoint: SSHEndpoint, publicKey: Data) -> Decision {
        guard let existing = host(for: endpoint) else { return .unknown }
        // Compared byte for byte: the value is public, so constant time is not the point, exactness is.
        return existing.publicKey == publicKey ? .match(existing) : .changed(existing)
    }

    /// Replacing is only reached through the first-sight path: a changed key refuses the connection, so an entry is overwritten only after the user forgets it.
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
