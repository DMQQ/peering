import Crypto
import Foundation
import RemoteCore
import os

private let passcodeLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// A random salt and the digest of the passcode under it, so equal passcodes on two servers do not share bytes.
public struct SSHPasscodeHash: Codable, Sendable, Equatable {
    public var salt: Data
    public var hash: Data

    public init(salt: Data, hash: Data) {
        self.salt = salt
        self.hash = hash
    }
}

/// One Keychain entry holding a dictionary, keyed by host id (``SSHCredentialStore``'s shape). Six digits is a million possibilities, so the salted SHA-256 is no defence against anyone who can read the blob; the Keychain ACL and `AfterFirstUnlockThisDeviceOnly` are the protection, and the digest keeps backups and dumps from handing over the number.
public struct SSHPasscodeStore: Sendable {
    public static let service = "pl.dmq.peering.ssh.passcodes"
    private static let account = "passcodes"

    public static let length = 6

    private let backend: SSHSecretBackend

    public init(backend: SSHSecretBackend = KeychainSecretBackend()) {
        self.backend = backend
    }

    public static func isValid(_ passcode: String) -> Bool {
        passcode.count == length && passcode.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public func all() -> [String: SSHPasscodeHash] {
        guard let data = backend.read(service: Self.service, account: Self.account) else { return [:] }
        do {
            return try JSONDecoder().decode([String: SSHPasscodeHash].self, from: data)
        } catch {
            // Logged and returned empty rather than crashing, as ``SSHCredentialStore`` does.
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

    /// Returns whether it was written; a locked server with nothing stored behind it cannot be opened, so the caller must not report success on `false`.
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

    /// `false` for a server with none, so "nothing is stored" can never be a way through a lock.
    public func verify(_ passcode: String, for hostID: UUID) -> Bool {
        guard let stored = hash(for: hostID) else { return false }
        // Constant time: the rule for a secret comparison holds whether or not a caller can exploit breaking it.
        return ConstantTime.equals(Self.digest(passcode, salt: stored.salt), stored.hash)
    }

    @discardableResult
    public func remove(for hostID: UUID) -> Bool {
        var passcodes = all()
        guard passcodes.removeValue(forKey: hostID.uuidString) != nil else { return true }
        return write(passcodes)
    }

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
