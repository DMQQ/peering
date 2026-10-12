import Foundation
import Security
import os

/// "Not found" and "unavailable" are different answers: the first is a fresh install, the second is a locked or failing Keychain whose contents are unknown and must not be overwritten.
enum PinRead: Equatable, Sendable {
    case found(Data)
    case notFound
    case unavailable(OSStatus)
}

/// The seam for ``ClientPinStore``'s failure rules, so tests can lock the Keychain.
protocol ClientPinBacking: Sendable {
    func read(_ slot: PinSlot) -> PinRead
    func write(_ data: Data, to slot: PinSlot) -> Bool
}

struct KeychainClientPinBacking: ClientPinBacking {
    let service: String
    let account: String

    static let backupSuffix = ".backup"

    private func name(_ slot: PinSlot) -> String {
        slot == .primary ? account : account + Self.backupSuffix
    }

    func read(_ slot: PinSlot) -> PinRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name(slot),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(SecretStore.attributes(query), &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .unavailable(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            transportLog.error("could not read client pins: OSStatus \(status, privacy: .public)")
            return .unavailable(status)
        }
    }

    func write(_ data: Data, to slot: PinSlot) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name(slot),
        ]
        let status = SecItemUpdate(SecretStore.attributes(query), [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            transportLog.error("could not update client pins: OSStatus \(status, privacy: .public)")
            return false
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = Self.accessibility
        let added = SecItemAdd(SecretStore.attributes(insert), nil)
        if added != errSecSuccess {
            transportLog.error("could not add client pins: OSStatus \(added, privacy: .public)")
        }
        return added == errSecSuccess
    }

    private static var accessibility: CFString {
        #if os(iOS)
        return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #else
        return kSecAttrAccessibleAfterFirstUnlock
        #endif
    }
}
