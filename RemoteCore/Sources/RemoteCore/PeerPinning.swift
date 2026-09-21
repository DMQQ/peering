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
    private let storage: any PinStorage
    private var pins: [String: Data]

    public init(service: String, account: String = "paired-clients") {
        self.storage = KeychainPinStorage(service: service, account: account)
        pins = Self.read(storage)
    }

    /// The same store over something other than the Keychain, for tests.
    ///
    /// Internal rather than public: nothing that ships should be able to point a trust store at a
    /// file, and the reason this exists at all is that the store's rules about *failure* had no way
    /// to be exercised while the only door in was the real Keychain.
    init(storage: any PinStorage) {
        self.storage = storage
        pins = Self.read(storage)
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
            guard Self.write(pins, to: storage) else {
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
            guard Self.write(pins, to: storage) else {
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
            return Self.write(pins, to: storage)
        }
    }

    /// The pins as stored, or an empty store.
    ///
    /// **Empty is the answer to every failure here, and that is a decision rather than a shrug.**
    /// The caller cannot act on the difference between "nothing stored" and "could not read", and
    /// the alternative (refusing to start, or holding no store at all) would leave a user unable
    /// to connect to a Mac they are already paired with. What it costs is a re-pairing, and the log
    /// line below is what makes the difference visible to whoever reads it.
    private static func read(_ storage: any PinStorage) -> [String: Data] {
        guard let data = storage.read() else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: Data].self, from: data) else {
            pinLog.error("pin store exists but could not be decoded; treating as empty")
            return [:]
        }
        return decoded
    }

    private static func write(_ pins: [String: Data], to storage: any PinStorage) -> Bool {
        guard let data = try? JSONEncoder().encode(pins) else {
            pinLog.error("could not encode pins")
            return false
        }
        return storage.write(data)
    }
}

/// Where a pin store keeps its bytes.
///
/// **One implementation ships and it is the Keychain.** This exists because two of the store's rules
/// are about what happens when storage *fails*, and neither could be exercised while the only way
/// into the store was the real Keychain: that a write which does not land must not leave the
/// in-memory copy claiming a pairing the next launch will not find, and that a read which cannot be
/// decoded is treated as an empty store rather than as whatever the bytes happened to say. Those are
/// the rules that decide whether a user is told they are paired when they are not.
public protocol PinStorage: Sendable {
    /// The stored bytes, or `nil` when there is nothing to read or nothing readable. A failure and
    /// an empty store are deliberately the same answer; see the note in ``PinStore/read(_:)``.
    func read() -> Data?
    /// Whether the bytes are now stored. `false` is a failure the caller must not ignore.
    func write(_ data: Data) -> Bool
}

/// The Keychain, which is what ships. See ``PinStore`` for why the store is here rather than in a
/// file the user owns.
struct KeychainPinStorage: PinStorage {
    let service: String
    let account: String

    func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(SecretStore.attributes(query), &item)

        // errSecItemNotFound is the ordinary first-run case. Any other failure means the store
        // exists but is unreachable, and since an unreadable store is indistinguishable from an
        // empty one, every paired peer would silently be treated as a stranger and asked to pair
        // again. That is worth a loud log line.
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                pinLog.error("could not read pins: OSStatus \(status, privacy: .public)")
            }
            return nil
        }
        return item as? Data
    }

    func write(_ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updates: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(
            SecretStore.attributes(query),
            updates as CFDictionary
        )
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
        let addStatus = SecItemAdd(SecretStore.attributes(insert), nil)
        if addStatus != errSecSuccess {
            pinLog.error("could not add pins: OSStatus \(addStatus, privacy: .public)")
        }
        return addStatus == errSecSuccess
    }
}
