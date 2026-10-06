import Foundation
import Security
import os

private let pinLog = Logger(subsystem: "pl.dmq.peering", category: "pins")

/// Pins the `SubjectPublicKeyInfo` rather than certificate bytes, so either side can re-mint its certificate without invalidating a pin, with no ASN.1 parsing (for P-256, the 65-byte point `0x04 ‖ X ‖ Y`).
public enum SPKI {
    public static func bytes(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(key, &error) else { return nil }
        return raw as Data
    }

    /// Constant-time: the attacker controls the presented key.
    public static func matches(_ lhs: Data, _ rhs: Data) -> Bool {
        ConstantTime.equals(lhs, rhs)
    }
}

/// Stored in the Keychain though the values are public: integrity is the point. These bytes decide who may drive this Mac, and a plist in the home directory is writable by anything running as the user.
/// Pass a distinct `service` so a host-and-client machine keeps two trust stores.
public final class PinStore: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: any PinStorage
    private var pins: [String: Data]

    public init(service: String, account: String = "paired-clients") {
        self.storage = KeychainPinStorage(service: service, account: account)
        pins = Self.read(storage)
    }

    /// For tests; internal so nothing that ships can point a trust store at a file.
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

    /// For a TLS verify block, which knows the presented key but not the claimed ID.
    public func contains(publicKey: Data) -> Bool {
        lock.withLock { pins.values.contains { SPKI.matches($0, publicKey) } }
    }

    /// Stores a pin. Returns `false` if the Keychain write failed, in which case the caller must
    /// not report a successful pairing: the next connection would silently fail.
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

    /// Empty is the answer to every failure: refusing would leave a user unable to connect to a paired Mac, and the cost is a re-pairing.
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

/// The seam exists for the store's failure rules: a write that does not land must not leave the in-memory copy claiming a pairing, and an undecodable read is an empty store.
public protocol PinStorage: Sendable {
    func read() -> Data?
    /// Whether the bytes are now stored. `false` is a failure the caller must not ignore.
    func write(_ data: Data) -> Bool
}

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
        // exists but is unreachable, and every paired peer would be treated as a stranger.
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
