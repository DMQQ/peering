import Foundation
import Security

/// The data protection keychain, so an item belongs to an access group (the team's `application-identifier`) rather than a certificate's code requirement: a rebuild signed differently is not a new app and macOS does not prompt per item.
/// Items in the login keychain do not carry over: the host mints a new identity and every paired phone re-pairs once.
/// `kSecUseDataProtectionKeychain` must be in every query; a forgotten one builds fine and quietly uses the other keychain, hence one function.
public enum SecretStore {
    /// `attributes`, as an item of this store. Public because the app keeps the relay's API key through it too; also passed to `SecKeyCreateRandomKey`.
    public static func attributes(_ attributes: [String: Any]) -> CFDictionary {
        var scoped = attributes
        if canClaimAnItem { scoped[kSecUseDataProtectionKeychain as String] = true }
        return scoped as CFDictionary
    }

    /// Whether this process may claim a data protection item. The entitlement needs a provisioning profile; without it every query fails with `errSecMissingEntitlement`, so such a process (`Tools/PeeringProbe`) uses the login keychain.
    private static let canClaimAnItem: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let identifier = SecTaskCopyValueForEntitlement(
            task, "com.apple.application-identifier" as CFString, nil
        )
        return identifier != nil
        #else
        // iOS has one keychain and it is this one, whatever the process can claim.
        return true
        #endif
    }()
}
