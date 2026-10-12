import Foundation
import Network
import Security
import os

/// Where a client keeps the hosts it has paired with, keyed by the host's `serverID`.
///
/// On iOS the item is `…ThisDeviceOnly`: a pin restored onto a different device would hand this
/// device's trust to whoever restored the backup.
///
/// A Keychain that cannot be read (locked, `errSecInteractionNotAllowed`) is not an empty one. While
/// the store is ``isUnreadable`` it refuses to write, and every write re-reads first, so a pairing
/// can never replace the pins it could not see. A second item holds the last good copy.
public final class ClientPinStore: @unchecked Sendable {
    private let lock = NSLock()
    private let backing: any ClientPinBacking
    private var pins: [String: Data] = [:]
    private var unreadable = false
    private var unreadableReported = false
    private let alarm: PinStoreAlarm
    /// Set under the lock when the store first turns unreadable, raised once the lock is released so a handler may call back in.
    private var alarmDue: UnreadableAlarm?

    private struct UnreadableAlarm { let status: Int32? }

    public static let standard = ClientPinStore(service: "pl.dmq.peering.client.pins")

    public convenience init(service: String, account: String = "paired-hosts") {
        self.init(backing: KeychainClientPinBacking(service: service, account: account))
    }

    init(backing: any ClientPinBacking, alarm: PinStoreAlarm = .shared) {
        self.backing = backing
        self.alarm = alarm
        _ = locked { reload() }
    }

    public var hostIDs: [String] { readable { $0.keys.sorted() } }
    public var isEmpty: Bool { readable { $0.isEmpty } }

    /// True while the Keychain cannot be read. Pins then look absent, which is not the same as the Mac being unpaired.
    public var isUnreadable: Bool { locked { retryIfUnreadable(); return unreadable } }

    public func pin(for hostID: String) -> Data? { readable { $0[hostID] } }

    public func contains(publicKey: Data) -> Bool {
        readable { $0.values.contains { SPKI.matches($0, publicKey) } }
    }

    /// Once per launch, so the user is told when pins could not be read and not on every connection attempt.
    public func takeUnreadableNotice() -> Bool {
        locked {
            retryIfUnreadable()
            guard unreadable, !unreadableReported else { return false }
            unreadableReported = true
            return true
        }
    }

    /// - Returns: `false` if the Keychain could not be read or written, in which case the caller must not report a
    ///   successful pairing: the user would be asked to pair again on the very next connection.
    @discardableResult
    public func record(hostID: String, publicKey: Data) -> Bool {
        change { $0[hostID] = publicKey }
    }

    @discardableResult
    public func remove(hostID: String) -> Bool {
        change { $0.removeValue(forKey: hostID) }
    }

    @discardableResult
    public func removeAll() -> Bool {
        change { $0.removeAll() }
    }

    /// Runs `body` under the lock and raises the alarm it asked for after the lock is released.
    private func locked<T>(_ body: () -> T) -> T {
        let (result, due) = lock.withLock { () -> (T, UnreadableAlarm?) in
            let result = body()
            defer { alarmDue = nil }
            return (result, alarmDue)
        }
        if let due { alarm.raise(status: due.status) }
        return result
    }

    private func readable<T>(_ body: ([String: Data]) -> T) -> T {
        locked {
            retryIfUnreadable()
            return body(pins)
        }
    }

    private func retryIfUnreadable() {
        if unreadable { _ = reload() }
    }

    private func change(_ edit: (inout [String: Data]) -> Void) -> Bool {
        locked {
            guard reload() else { return false }
            var next = pins
            edit(&next)
            guard let data = try? JSONEncoder().encode(next), backing.write(data, to: .primary) else {
                transportLog.error("could not store client pins")
                return false
            }
            pins = next
            if !backing.write(data, to: .backup) { transportLog.error("could not store the client pin backup") }
            return true
        }
    }

    /// - Returns: `false` when the store could not be read; the in-memory pins are then left as they were.
    private func reload() -> Bool {
        switch Self.load(backing) {
        case .pins(let loaded):
            pins = loaded
            unreadable = false
            return true
        case .absent:
            unreadable = false
            return true
        case .unreadable(let status):
            if !unreadable { alarmDue = UnreadableAlarm(status: status) }
            unreadable = true
            return false
        }
    }

    private enum Loaded { case pins([String: Data]), absent, unreadable(status: Int32?) }

    /// A blob that exists but will not decode is not an empty store: treating it as one would let the next pairing overwrite it.
    private static func load(_ backing: any ClientPinBacking) -> Loaded {
        var primaryUndecodable = false
        switch backing.read(.primary) {
        case .unavailable(let status):
            return .unreadable(status: status)
        case .found(let data):
            if let decoded = decode(data) { return .pins(decoded) }
            transportLog.error("client pin store could not be decoded; trying the backup")
            primaryUndecodable = true
        case .notFound:
            break
        }
        switch backing.read(.backup) {
        case .unavailable(let status):
            return .unreadable(status: status)
        case .found(let data):
            guard let decoded = decode(data) else { return .unreadable(status: nil) }
            transportLog.error("client pins restored from the backup item")
            return .pins(decoded)
        case .notFound:
            return primaryUndecodable ? .unreadable(status: nil) : .absent
        }
    }

    private static func decode(_ data: Data) -> [String: Data]? {
        try? JSONDecoder().decode([String: Data].self, from: data)
    }
}
