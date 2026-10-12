import Foundation
import Network
import Security
import os

/// Where a client keeps the hosts it has paired with, keyed by the host's `serverID`.
///
/// On iOS the item is `…ThisDeviceOnly`: a pin restored onto a different device would hand this
/// device's trust to whoever restored the backup.
public final class ClientPinStore: @unchecked Sendable {
    private let lock = NSLock()
    private let service: String
    private let account: String
    private var pins: [String: Data]

    public static let standard = ClientPinStore(service: "pl.dmq.peering.client.pins")

    public init(service: String, account: String = "paired-hosts") {
        self.service = service
        self.account = account
        pins = Self.read(service: service, account: account)
    }

    public var hostIDs: [String] { lock.withLock { pins.keys.sorted() } }
    public var isEmpty: Bool { lock.withLock { pins.isEmpty } }

    public func pin(for hostID: String) -> Data? { lock.withLock { pins[hostID] } }

    public func contains(publicKey: Data) -> Bool {
        lock.withLock { pins.values.contains { SPKI.matches($0, publicKey) } }
    }

    /// - Returns: `false` if the Keychain write failed, in which case the caller must not report a
    ///   successful pairing: the user would be asked to pair again on the very next connection.
    @discardableResult
    public func record(hostID: String, publicKey: Data) -> Bool {
        lock.withLock {
            let previous = pins[hostID]
            pins[hostID] = publicKey
            guard Self.write(pins, service: service, account: account) else {
                if let previous { pins[hostID] = previous } else { pins.removeValue(forKey: hostID) }
                return false
            }
            return true
        }
    }

    @discardableResult
    public func remove(hostID: String) -> Bool {
        lock.withLock {
            let previous = pins.removeValue(forKey: hostID)
            guard Self.write(pins, service: service, account: account) else {
                if let previous { pins[hostID] = previous }
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

    private static var accessibility: CFString {
        #if os(iOS)
        return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #else
        return kSecAttrAccessibleAfterFirstUnlock
        #endif
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
        let status = SecItemCopyMatching(SecretStore.attributes(query), &item)

        guard status == errSecSuccess else {
            // errSecItemNotFound is the ordinary first-run case. Anything else means the store
            // exists but is unreadable, which is indistinguishable from an empty one: every paired
            // Mac would silently become a stranger and the user would be asked to pair again.
            if status != errSecItemNotFound {
                transportLog.error("could not read client pins: OSStatus \(status, privacy: .public)")
                PinStoreAlarm.raise(status: status)
            }
            return [:]
        }

        guard let data = item as? Data,
              let decoded = try? JSONDecoder().decode([String: Data].self, from: data)
        else {
            transportLog.error("client pin store exists but could not be decoded; treating as empty")
            PinStoreAlarm.raise(status: nil)
            return [:]
        }
        return decoded
    }

    private static func write(_ pins: [String: Data], service: String, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(pins) else {
            transportLog.error("could not encode client pins")
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemUpdate(
            SecretStore.attributes(query),
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            transportLog.error("could not update client pins: OSStatus \(status, privacy: .public)")
            return false
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = accessibility
        let addStatus = SecItemAdd(SecretStore.attributes(insert), nil)
        if addStatus != errSecSuccess {
            transportLog.error("could not add client pins: OSStatus \(addStatus, privacy: .public)")
        }
        return addStatus == errSecSuccess
    }
}
