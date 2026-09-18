import Crypto
import Foundation
import RemoteCore
import os

private let passcodeLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// A passcode as it is kept: a random salt, and the digest of the passcode under it.
///
/// The salt is what stops the stored blob from being a lookup table. Without one, two servers the
/// user gave the same passcode would carry the same bytes — and one of those servers being looked
/// up somewhere else would be enough to recognise the other.
public struct SSHPasscodeHash: Codable, Sendable, Equatable {
    public var salt: Data
    public var hash: Data

    public init(salt: Data, hash: Data) {
        self.salt = salt
        self.hash = hash
    }
}

/// The per-server passcodes, keyed by host id.
///
/// One Keychain entry holding a dictionary, which is ``SSHCredentialStore``'s shape for the same
/// reason: the alternative is an entry per server with no index of which servers have one, and then
/// "is this one locked" becomes a Keychain lookup per row of a list.
///
/// **What the digest is and is not for.** Six digits is a million possibilities, so a salted
/// SHA-256 is not a defence against anyone who can *read* this blob — a million hashes is a moment.
/// What actually protects a passcode is the Keychain entry's ACL and its
/// `AfterFirstUnlockThisDeviceOnly` accessibility, exactly as it protects a stored password. The
/// digest is there so that the other things that happen to a blob of bytes — a device backup, a
/// diagnostic dump, a crash report — do not hand over a six-digit number the user has very likely
/// used somewhere that matters more than this.
public struct SSHPasscodeStore: Sendable {
    public static let service = "pl.dmq.peering.ssh.passcodes"
    private static let account = "passcodes"

    /// Six digits, which is the length the app already uses for a pairing code — and long enough
    /// that guessing one on a pad is not a realistic way past it.
    public static let length = 6

    private let backend: SSHSecretBackend

    public init(backend: SSHSecretBackend = KeychainSecretBackend()) {
        self.backend = backend
    }

    /// Whether a typed passcode is one this store would accept, so the pad and the editor agree on
    /// what "six digits" means without either of them counting characters for itself.
    public static func isValid(_ passcode: String) -> Bool {
        passcode.count == length && passcode.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Everything stored, or an empty dictionary when nothing is.
    public func all() -> [String: SSHPasscodeHash] {
        guard let data = backend.read(service: Self.service, account: Self.account) else { return [:] }
        do {
            return try JSONDecoder().decode([String: SSHPasscodeHash].self, from: data)
        } catch {
            // Logged and returned as empty rather than as a crash — the same call
            // ``SSHCredentialStore`` makes, and for the same reason: a blob that will not decode is
            // a store something has corrupted, and there is nothing to be done about it but say so.
            passcodeLog.error("could not read stored SSH passcodes: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    public func hash(for hostID: UUID) -> SSHPasscodeHash? {
        all()[hostID.uuidString]
    }

    public func hasPasscode(for hostID: UUID) -> Bool {
        hash(for: hostID) != nil
    }

    /// Sets a passcode, replacing any the server already had.
    ///
    /// Returns whether it was actually written, and the caller must not report success on `false` —
    /// a server marked as locked with nothing stored behind it is a server that cannot be opened.
    @discardableResult
    public func set(_ passcode: String, for hostID: UUID) -> Bool {
        guard Self.isValid(passcode) else { return false }

        let salt = Self.freshSalt()
        var passcodes = all()
        passcodes[hostID.uuidString] = SSHPasscodeHash(
            salt: salt,
            hash: Self.digest(passcode, salt: salt)
        )
        return write(passcodes)
    }

    /// Whether a typed passcode is the one this server was given.
    ///
    /// `false` for a server that has none, so a caller cannot turn "nothing is stored" into a way
    /// through a lock by passing anything at all.
    public func verify(_ passcode: String, for hostID: UUID) -> Bool {
        guard let stored = hash(for: hostID) else { return false }
        // Constant time, even though the comparison is over digests and the attacker would have to
        // be holding the Keychain entry to have anything to compare against: the rule for a secret
        // comparison is the same whether or not a particular caller can exploit breaking it.
        return ConstantTime.equals(Self.digest(passcode, salt: stored.salt), stored.hash)
    }

    @discardableResult
    public func remove(for hostID: UUID) -> Bool {
        var passcodes = all()
        guard passcodes.removeValue(forKey: hostID.uuidString) != nil else { return true }
        return write(passcodes)
    }

    /// Clears every passcode. For the reset path, and for tests.
    @discardableResult
    public func removeAll() -> Bool {
        backend.remove(service: Self.service, account: Self.account)
    }

    private func write(_ passcodes: [String: SSHPasscodeHash]) -> Bool {
        do {
            return backend.write(
                try JSONEncoder().encode(passcodes),
                service: Self.service,
                account: Self.account
            )
        } catch {
            passcodeLog.error("could not encode SSH passcodes: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func digest(_ passcode: String, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(passcode.utf8))
        return Data(hasher.finalize())
    }

    private static func freshSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
