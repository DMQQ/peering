import Foundation
import Security

/// Which keychain every secret in this package is kept in.
///
/// **The data protection keychain, and the reason is who is allowed to read the item.** A secret in
/// the login keychain carries an access control list naming the applications that may read it, and
/// what that list holds is a *code requirement*: the certificate the app was signed with. Sign the
/// same app with a different certificate and the item stops being yours. macOS cannot tell that
/// apart from a stranger asking for it, so it does the only thing it can and asks the user, once per
/// item, on every attempt. `AGENTS.md` carries this as trap 20, "sign stably", and the shape of the
/// trap is that the *build* changed rather than the app.
///
/// The data protection keychain has no such list. An item belongs to an **access group**, the access
/// group is the app's `application-identifier` entitlement, and that entitlement comes from the team
/// rather than from the certificate. This app's development builds and its notarized Developer ID
/// build are signed by two different certificates and carry the same identifier,
/// `55RA6Q9VSR.pl.dmq.peering.host`, so a rebuild is not a new application as far as this store is
/// concerned and no prompt is owed. That is the whole of the change.
///
/// **It is not the same keychain, so it is not the same items.** Everything already stored lives in
/// the other one and stays there, invisible to this code from the moment it ships. The host will not
/// find its identity, will mint a new one, and every paired phone has to pair again. That is a
/// one-time cost, paid deliberately, and it buys a store that survives the next certificate.
///
/// **Nothing here is a preference, which is why it is one function rather than a constant.**
/// `kSecUseDataProtectionKeychain` has to appear in every query and every set of attributes, and
/// there are six such dictionaries across three files. A constant is a thing each site has to
/// remember to merge; this is a thing the call cannot be written without. The failure mode of the
/// forgotten one is not a build error either. It is a single call quietly reading and writing the
/// *other* keychain, which is how an app comes to have two identities and no explanation for either.
public enum SecretStore {
    /// `attributes`, as an item of this store.
    ///
    /// Passed to every `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate` and `SecItemDelete`, and
    /// to `SecKeyCreateRandomKey`, where the same dictionary decides where a permanent key is kept.
    ///
    /// Public because this package is not the only caller: the app keeps the relay's API key
    /// through the same call. On iOS the flag is already the only answer the platform has, so it
    /// changes nothing there, and it is asked for anyway so that "every keychain call in this
    /// repository goes through one function" is a thing `grep` can check.
    public static func attributes(_ attributes: [String: Any]) -> CFDictionary {
        var scoped = attributes
        if canClaimAnItem { scoped[kSecUseDataProtectionKeychain as String] = true }
        return scoped as CFDictionary
    }

    /// Whether this process is entitled to an item in the data protection keychain.
    ///
    /// **The question is asked rather than assumed, and the answer is not always yes.** An item
    /// there belongs to an access group, the group is the app's `application-identifier`, and that
    /// entitlement only exists on a build that was signed with a provisioning profile. Ask for the
    /// data protection keychain without one and the call does not fall back, it *fails*:
    /// `errSecMissingEntitlement`, every time, for every item.
    ///
    /// That is the whole reason this check is here. The apps have the entitlement and this is the
    /// store they should be using. `Tools/MacCastProbe` is the same code linked into a SwiftPM
    /// executable that `Tools/run-probe.sh` signs with an identity and no entitlements at all, and
    /// it holds a client identity in the keychain by design. Asking for a group it cannot have would
    /// not have made the probe safer, it would have stopped the probe working, and it would have
    /// stopped it in the way this file exists to prevent: silently, from the inside.
    ///
    /// A process that cannot claim an item is not left without one. It gets the login keychain,
    /// which is what it was using before this file existed, and which the probe's stable signing
    /// identity is already arranged around.
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
