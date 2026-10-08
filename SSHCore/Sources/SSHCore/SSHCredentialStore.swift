import Foundation
import os

private let log = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// An enum rather than a `password: String?` so key auth is a case: adding one needs no migration, and a password blob written by an older build decodes unchanged (a test pins that against a hand-written blob).
/// `Codable` here is not forward-compatible, which is fine because the Keychain entry is `ThisDeviceOnly`: no blob can arrive from another device.
public enum SSHCredential: Codable, Sendable, Equatable {
    case password(String)
    /// A key pair, both halves: the public half is what the user installs on the server.
    case key(SSHKeyPair)
}

/// One Keychain entry holding a dictionary (``ClientPinStore``'s shape), so "does this host have a saved password" is not a Keychain lookup per row.
public struct SSHCredentialStore: Sendable {
    public static let service = "pl.dmq.peering.ssh.credentials"
    private static let account = "credentials"

    private let backend: SSHSecretBackend

    public init(backend: SSHSecretBackend = KeychainSecretBackend()) {
        self.backend = backend
    }

    public func all() -> [String: SSHCredential] {
        guard let data = backend.read(service: Self.service, account: Self.account) else {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: SSHCredential].self, from: data)
        } catch {
            // A blob that will not decode is a corrupted store, not "no credentials": returning empty would re-ask every password and overwrite it on the next save.
            log.error("could not read stored SSH credentials: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    public func credential(for hostID: UUID) -> SSHCredential? {
        all()[hostID.uuidString]
    }

    public func hasCredential(for hostID: UUID) -> Bool {
        credential(for: hostID) != nil
    }

    /// The return value matters: the caller tells the user "saved" or "you will be asked again" from it.
    @discardableResult
    public func save(_ credential: SSHCredential, for hostID: UUID) -> Bool {
        var credentials = all()
        credentials[hostID.uuidString] = credential
        return write(credentials)
    }

    @discardableResult
    public func remove(for hostID: UUID) -> Bool {
        var credentials = all()
        guard credentials.removeValue(forKey: hostID.uuidString) != nil else { return true }
        return write(credentials)
    }

    @discardableResult
    public func removeAll() -> Bool {
        backend.remove(service: Self.service, account: Self.account)
    }

    private func write(_ credentials: [String: SSHCredential]) -> Bool {
        do {
            let data = try JSONEncoder().encode(credentials)
            return backend.write(data, service: Self.service, account: Self.account)
        } catch {
            log.error("could not encode SSH credentials: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
