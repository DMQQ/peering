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
///
/// A store that cannot be read is not an empty one: it refuses to write until it can read, so a first pairing at a locked login can never replace the pins of every other device. A second item holds a copy for the day the first is lost or corrupt.
public final class PinStore: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: any PinStorage
    private var pins: [String: Data]
    private var loaded: Bool

    public init(service: String, account: String = "paired-clients") {
        self.storage = KeychainPinStorage(service: service, account: account)
        (pins, loaded) = Self.load(storage)
    }

    /// For tests; internal so nothing that ships can point a trust store at a file.
    init(storage: any PinStorage) {
        self.storage = storage
        (pins, loaded) = Self.load(storage)
    }

    /// Whether the last read of the storage succeeded. While `false`, changes are refused.
    public var isAvailable: Bool {
        lock.withLock { loaded }
    }

    public var peerIDs: [String] {
        lock.withLock { current().keys.sorted() }
    }

    public var isEmpty: Bool {
        lock.withLock { current().isEmpty }
    }

    public func pin(for peerID: String) -> Data? {
        lock.withLock { current()[peerID] }
    }

    /// For a TLS verify block, which knows the presented key but not the claimed ID.
    public func contains(publicKey: Data) -> Bool {
        lock.withLock { current().values.contains { SPKI.matches($0, publicKey) } }
    }

    /// Stores a pin. Returns `false` if the storage could not be read or written, in which case the caller must
    /// not report a successful pairing: the next connection would silently fail.
    @discardableResult
    public func record(peerID: String, publicKey: Data) -> Bool {
        change { $0[peerID] = publicKey }
    }

    @discardableResult
    public func remove(peerID: String) -> Bool {
        change { $0.removeValue(forKey: peerID) }
    }

    @discardableResult
    public func removeAll() -> Bool {
        lock.withLock {
            guard Self.write([:], to: storage) else { return false }
            pins = [:]
            loaded = true
            return true
        }
    }

    /// The pins as last read, read again first when the last read failed.
    private func current() -> [String: Data] {
        if !loaded { (pins, loaded) = Self.load(storage) }
        return pins
    }

    /// Reads the storage afresh before applying the change, so what was written elsewhere or before a failed launch read is never overwritten from a stale copy.
    private func change(_ apply: (inout [String: Data]) -> Void) -> Bool {
        lock.withLock {
            let fresh = Self.load(storage)
            guard fresh.loaded else {
                (pins, loaded) = fresh
                pinLog.error("pin store unavailable; refusing to change it")
                return false
            }
            var updated = fresh.pins
            apply(&updated)
            guard Self.write(updated, to: storage) else {
                (pins, loaded) = fresh
                return false
            }
            pins = updated
            loaded = true
            return true
        }
    }

    private static func load(_ storage: any PinStorage) -> (pins: [String: Data], loaded: Bool) {
        switch storage.read(.primary) {
        case .found(let data):
            if let decoded = decode(data) { return (decoded, true) }
            pinLog.error("pin store exists but could not be decoded; trying the backup")
            return (backupPins(storage) ?? [:], true)
        case .notFound:
            switch storage.read(.backup) {
            case .found(let data): return (decode(data) ?? [:], true)
            case .notFound: return ([:], true)
            case .unavailable: return ([:], false)
            }
        case .unavailable:
            return (backupPins(storage) ?? [:], false)
        }
    }

    private static func backupPins(_ storage: any PinStorage) -> [String: Data]? {
        guard case .found(let data) = storage.read(.backup) else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data) -> [String: Data]? {
        try? JSONDecoder().decode([String: Data].self, from: data)
    }

    /// The backup is best effort: losing it costs nothing the primary does not already hold.
    private static func write(_ pins: [String: Data], to storage: any PinStorage) -> Bool {
        guard let data = try? JSONEncoder().encode(pins) else {
            pinLog.error("could not encode pins")
            return false
        }
        guard storage.write(data, to: .primary) else { return false }
        if !storage.write(data, to: .backup) {
            pinLog.error("could not write the pin backup")
        }
        return true
    }
}
