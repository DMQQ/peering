import Foundation
import Security
import os

private let pinLog = Logger(subsystem: "pl.dmq.peering", category: "pins")

/// What a read of the pin storage found. `notFound` is the ordinary first run; `unavailable` means the item may well exist but cannot be reached now, as with a locked Keychain at login.
public enum PinStorageRead: Sendable, Equatable {
    case found(Data)
    case notFound
    case unavailable
}

public enum PinSlot: Sendable {
    case primary
    case backup
}

/// The seam exists for the store's failure rules: a write that does not land must not leave the in-memory copy claiming a pairing, and a store that cannot be read must not be mistaken for an empty one.
public protocol PinStorage: Sendable {
    func read(_ slot: PinSlot) -> PinStorageRead
    /// Whether the bytes are now stored. `false` is a failure the caller must not ignore.
    func write(_ data: Data, to slot: PinSlot) -> Bool
}

struct KeychainPinStorage: PinStorage {
    let service: String
    let account: String

    private func account(for slot: PinSlot) -> String {
        slot == .primary ? account : account + "-backup"
    }

    func read(_ slot: PinSlot) -> PinStorageRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: slot),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(SecretStore.attributes(query), &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .unavailable }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            // errSecInteractionNotAllowed and its kin: the item exists but cannot be reached now, and every paired peer would be treated as a stranger if this read as empty.
            pinLog.error("could not read pins: OSStatus \(status, privacy: .public)")
            return .unavailable
        }
    }

    func write(_ data: Data, to slot: PinSlot) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: slot),
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
