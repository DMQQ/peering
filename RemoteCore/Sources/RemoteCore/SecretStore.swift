import Foundation
import Security

/// Which keychain every secret in this package is kept in.
///
/// The data protection keychain, because of who is allowed to read the item. A secret in the login
/// keychain carries an access control list holding a code requirement, the certificate the app was
/// signed with, so signing the same app with a different certificate makes the item stop being
/// yours and macOS asks the user once per item, every attempt.
///
/// The data protection keychain has no such list: an item belongs to an access group, which is the
/// app's `application-identifier` entitlement, and that comes from the team rather than the
/// certificate. Both this app's development build and its notarized Developer ID build carry
/// `55RA6Q9VSR.pl.dmq.peering.host`, so a rebuild is not a new application to this store.
///
/// It is not the same keychain, so the items already stored there do not come with it: the host
/// mints a new identity and every paired phone has to pair again, once.
///
/// `kSecUseDataProtectionKeychain` has to appear in every query and every set of attributes, which
/// is why this is one function rather than a constant each site merges. A forgotten one does not
/// fail to build; it quietly reads and writes the other keychain.
public enum SecretStore {
    /// `attributes`, as an item of this store.
    ///
    /// Passed to every keychain call, including `SecKeyCreateRandomKey`, where the same dictionary
    /// decides where a permanent key is kept. Public because this package is not the only caller:
    /// the app keeps the relay's API key through the same call.
    public static func attributes(_ attributes: [String: Any]) -> CFDictionary {
        var scoped = attributes
        if canClaimAnItem { scoped[kSecUseDataProtectionKeychain as String] = true }
        return scoped as CFDictionary
    }

    /// Whether this process is entitled to an item in the data protection keychain.
    ///
    /// The entitlement only exists on a build signed with a provisioning profile. Asking for the
    /// data protection keychain without one does not fall back, it fails with
    /// `errSecMissingEntitlement`, every time, for every item, which is why the question is asked
    /// rather than assumed. A process that cannot claim an item gets the login keychain instead,
    /// which is what `Tools/MacCastProbe` holds its client identity in.
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
