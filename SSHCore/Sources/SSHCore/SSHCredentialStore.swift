import Foundation
import os

private let log = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// What the app knows to log in with.
///
/// An enum rather than a struct with a `password: String?` in it, so that key auth is a *case*
/// rather than a field somebody has to remember not to use. Version one only ever constructs
/// `.password` — but the shape is what decides how much work adding keys later is, and a case plus
/// a line in the connection is a morning. A `password: String?` that keys were meant to sit beside
/// is a migration: every stored blob is a password-shaped thing that has to be re-read and
/// re-written, on the one store where getting that wrong loses the user's logins.
///
/// That is how ``key(_:)`` arrived, and it cost exactly what the paragraph above promised: no
/// migration, no re-read, no blob rewritten. A password stored by the previous build decodes
/// unchanged into this one, because Swift's synthesized enum encoding names the *case* and the
/// `.password` arm's bytes do not move when a second case appears beside it. There is a test for
/// that, against a blob written in the old shape by hand, because "this should be compatible" is
/// the kind of claim that is worth being wrong about loudly.
///
/// A case rather than a field also settles the question a `password:` and a `key:` side by side
/// would leave open: which one wins when both are set. Neither does, because both cannot be.
///
/// `Codable` here is not forward-compatible — an older build cannot decode a case it does not know.
/// That is fine *because* the Keychain entry is `ThisDeviceOnly`: no blob can ever arrive from
/// another device, and a blob written by a newer build of this one is a blob from an app that has
/// already been updated.
public enum SSHCredential: Codable, Sendable, Equatable {
    case password(String)
    /// A key pair, both halves. The public half travels with the private one because it is what the
    /// user has to install on the server — see ``SSHKeyPair``.
    case key(SSHKeyPair)
}

/// The credentials, keyed by host id.
///
/// One Keychain entry holding a dictionary, which is ``ClientPinStore``'s shape for the same
/// reason: the alternative is an entry per host with no index of which hosts have one, and then
/// "does this host have a saved password" becomes a Keychain lookup per row in a list.
public struct SSHCredentialStore: Sendable {
    public static let service = "pl.dmq.peering.ssh.credentials"
    private static let account = "credentials"

    private let backend: SSHSecretBackend

    public init(backend: SSHSecretBackend = KeychainSecretBackend()) {
        self.backend = backend
    }

    /// Everything stored, or an empty dictionary when nothing is.
    public func all() -> [String: SSHCredential] {
        guard let data = backend.read(service: Self.service, account: Self.account) else {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: SSHCredential].self, from: data)
        } catch {
            // A blob that will not decode is not "no credentials" — it is a store that has been
            // corrupted by something, and silently returning an empty dictionary would have the
            // app ask for every password again and then overwrite this on the next save.
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

    /// Saves, and says whether it worked.
    ///
    /// The return value is not decoration: the caller tells the user "saved" or "you will be asked
    /// again next time" based on it, and a `false` silently treated as success is a checkbox that
    /// lies.
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

    /// Clears every credential. For the reset path, and for tests.
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
