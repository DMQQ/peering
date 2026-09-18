import Foundation
import Security
import os

private let secretLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// Where a secret is kept.
///
/// A protocol with two implementations rather than a call straight into the Keychain, and the
/// reason is testing rather than layering: a test binary that calls `SecItemAdd` can hang on a
/// prompt or come back `errSecMissingEntitlement` depending on how it was signed, so a store that
/// could only speak to the Keychain could only be tested by hand. Everything above this protocol —
/// which credentials exist, what happens when one cannot be written, when a host key is trusted —
/// is then ordinary logic with ordinary tests.
///
/// It is also the seam a future "keep this in the Secure Enclave" or "read from 1Password" would
/// use, without any of those being built now.
public protocol SSHSecretBackend: Sendable {
    func read(service: String, account: String) -> Data?
    /// Returns whether it was actually written. Callers must not report success on `false`.
    @discardableResult
    func write(_ data: Data, service: String, account: String) -> Bool
    @discardableResult
    func remove(service: String, account: String) -> Bool
}

/// The Keychain, following the rules `ClientPinStore` already set for this app.
///
/// Three of them, and none is optional:
///
/// - **`AfterFirstUnlockThisDeviceOnly`.** Readable at launch after a reboot before the first
///   unlock, and never restorable onto another device. The second half is what makes a credential
///   stop being able to travel, which matters more here than for a pin: a password that can appear
///   on another device is a password that can leak through a backup.
/// - **Writes report failure.** A silent `true` on a failed write is the exact bug the pin store's
///   own comment warns about — the user is told their password was saved and then asked for it
///   again with no idea why.
/// - **Unreadable is not empty.** Any status other than `errSecItemNotFound` is logged loudly
///   rather than returned as "no credentials", because those two lead to opposite behaviours: one
///   asks the user for a password, the other overwrites what is there.
public struct KeychainSecretBackend: SSHSecretBackend {
    public init() {}

    public func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            secretLog.error("keychain read failed (\(status, privacy: .public)) for \(service, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    public func write(_ data: Data, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Updated in place when it exists, so the accessibility attribute of an entry written by an
        // older build is rewritten rather than inherited.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else {
            secretLog.error("keychain update failed (\(updated, privacy: .public)) for \(service, privacy: .public)")
            return false
        }

        var insert = query
        insert.merge(attributes) { _, new in new }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else {
            secretLog.error("keychain add failed (\(added, privacy: .public)) for \(service, privacy: .public)")
            return false
        }
        return true
    }

    @discardableResult
    public func remove(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Not finding it is success: the caller asked for it to be gone and it is.
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Secrets in a dictionary, for tests and previews.
///
/// A class rather than a struct because the stores hold it and expect the same contents back; the
/// lock is what makes it `Sendable` without an actor in the way of a synchronous protocol.
public final class InMemorySecretBackend: SSHSecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    private func key(_ service: String, _ account: String) -> String { "\(service)/\(account)" }

    public func read(service: String, account: String) -> Data? {
        lock.withLock { storage[key(service, account)] }
    }

    @discardableResult
    public func write(_ data: Data, service: String, account: String) -> Bool {
        lock.withLock { storage[key(service, account)] = data }
        return true
    }

    @discardableResult
    public func remove(service: String, account: String) -> Bool {
        lock.withLock { storage.removeValue(forKey: key(service, account)) != nil }
    }

    /// Everything held, for a test that wants to assert something was *not* written.
    public var isEmpty: Bool {
        lock.withLock { storage.isEmpty }
    }
}
