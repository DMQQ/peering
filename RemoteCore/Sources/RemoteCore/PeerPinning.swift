import Foundation
import Security
import os

private let pinLog = Logger(subsystem: "pl.dmq.peering", category: "pins")

/// Helpers for pinning a peer by its public key.
///
/// Pinning targets the `SubjectPublicKeyInfo` — for our P-256 keys that is the 65-byte
/// uncompressed point `0x04 ‖ X ‖ Y`. Two properties make it the right choice over
/// pinning certificate bytes:
///
/// - Either side can re-mint its certificate (new serial number, new validity window) on
///   any launch without invalidating a single stored pin.
/// - Both sides obtain it through `SecKeyCopyExternalRepresentation`, which returns the
///   identical bytes, so the check needs no ASN.1 parsing at all.
public enum SPKI {
    /// Canonical public-key bytes of a certificate, or `nil` if the key is not extractable.
    public static func bytes(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(key, &error) else { return nil }
        return raw as Data
    }

    /// Constant-time comparison. Pins are fixed-size public values, but an attacker
    /// controls the presented key, so the comparison must not leak how far it matched.
    public static func matches(_ lhs: Data, _ rhs: Data) -> Bool {
        ConstantTime.equals(lhs, rhs)
    }
}

/// The peers a user has explicitly approved, keyed by their device ID.
///
/// Stored in the **Keychain** even though the values are public keys. Secrecy is not the
/// point — *integrity* is. These bytes decide who is allowed to drive this Mac, and the
/// Keychain is the only storage macOS actually protects against tampering. A plist in the
/// user's home directory would be writable by anything running as that user, which would
/// let a local process add a client of its choosing and then connect from the network.
///
/// The same type serves both roles; pass a distinct `service` so a machine acting as both
/// host and client keeps two independent trust stores.
public final class PinStore: @unchecked Sendable {
    private let lock = NSLock()
    private let service: String
    private let account: String
    private var pins: [String: Data]

    public init(service: String, account: String = "paired-clients") {
        self.service = service
        self.account = account
        pins = Self.read(service: service, account: account)
    }

    public var peerIDs: [String] {
        lock.withLock { pins.keys.sorted() }
    }

    public var isEmpty: Bool {
        lock.withLock { pins.isEmpty }
    }

    public func pin(for peerID: String) -> Data? {
        lock.withLock { pins[peerID] }
    }

    /// Whether any pinned peer matches this public key. Used by a TLS verify block, which
    /// knows the presented key but not yet the peer's claimed ID.
    public func contains(publicKey: Data) -> Bool {
        lock.withLock { pins.values.contains { SPKI.matches($0, publicKey) } }
    }

    /// Stores a pin. Returns `false` if the Keychain write failed — the caller must not
    /// report a successful pairing in that case, or the user would be told they are
    /// paired while the next connection silently fails.
    @discardableResult
    public func record(peerID: String, publicKey: Data) -> Bool {
        lock.withLock {
            let previous = pins[peerID]
            pins[peerID] = publicKey
            guard Self.write(pins, service: service, account: account) else {
                if let previous { pins[peerID] = previous } else { pins.removeValue(forKey: peerID) }
                return false
            }
            return true
        }
    }

    @discardableResult
    public func remove(peerID: String) -> Bool {
        lock.withLock {
            let previous = pins.removeValue(forKey: peerID)
            guard Self.write(pins, service: service, account: account) else {
                pins[peerID] = previous
                return false
            }
            return true
        }
    }

    @discardableResult
    public func removeAll() -> Bool {
        lock.withLock {
            pins.removeAll()
            return Self.write(pins, service: service, account: account)
        }
    }

    private static func read(service: String, account: String) -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        // errSecItemNotFound is the ordinary first-run case. Any other failure means the
        // store exists but is unreachable — and since an unreadable store is
        // indistinguishable from an empty one, every paired peer would silently be treated
        // as a stranger and asked to pair again. That is worth a loud log line.
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                pinLog.error("could not read pins: OSStatus \(status, privacy: .public)")
            }
            return [:]
        }

        guard let data = item as? Data,
              let decoded = try? JSONDecoder().decode([String: Data].self, from: data)
        else {
            pinLog.error("pin store exists but could not be decoded; treating as empty")
            return [:]
        }
        return decoded
    }

    private static func write(_ pins: [String: Data], service: String, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(pins) else {
            pinLog.error("could not encode pins")
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updates: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            pinLog.error("could not update pins: OSStatus \(status, privacy: .public)")
            return false
        }

        var insert = query
        insert[kSecValueData as String] = data
        // A host must be able to accept connections at login without the user present,
        // so this cannot be `WhenUnlocked`.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            pinLog.error("could not add pins: OSStatus \(addStatus, privacy: .public)")
        }
        return addStatus == errSecSuccess
    }
}
