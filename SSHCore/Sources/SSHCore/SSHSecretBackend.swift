import Foundation
import Security
import os

private let secretLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// A protocol so stores can be tested: a test binary that calls `SecItemAdd` can hang on a prompt or return `errSecMissingEntitlement`, depending on how it was signed.
public protocol SSHSecretBackend: Sendable {
    func read(service: String, account: String) -> Data?
    /// Returns whether it was actually written. Callers must not report success on `false`.
    @discardableResult
    func write(_ data: Data, service: String, account: String) -> Bool
    @discardableResult
    func remove(service: String, account: String) -> Bool
}

/// The Keychain, with three rules: `AfterFirstUnlockThisDeviceOnly` (readable at launch after reboot, never restorable onto another device); writes report failure (a silent `true` tells the user a password was saved when it was not); and unreadable is not empty (any status other than `errSecItemNotFound` is logged, because overwriting what is there is the opposite of asking for a password).
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

        // Updated in place so an entry written by an older build gets its accessibility attribute rewritten.
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
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Secrets in a dictionary for tests and previews. A class because stores expect the same contents back; the lock makes it `Sendable`.
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

    public var isEmpty: Bool {
        lock.withLock { storage.isEmpty }
    }
}
