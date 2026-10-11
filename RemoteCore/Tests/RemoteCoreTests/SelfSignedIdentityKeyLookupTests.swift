import Security
import Testing

@testable import RemoteCore

@Suite("When a missing identity key may be minted")
struct SelfSignedIdentityKeyLookupTests {
    @Test("a key that does not exist is minted")
    func missingKeyIsMinted() {
        #expect(SelfSignedIdentity.canMintKey(afterLookup: errSecItemNotFound))
    }

    @Test("a locked keychain does not mint a replacement key")
    func lockedKeychainKeepsTheKey() {
        #expect(!SelfSignedIdentity.canMintKey(afterLookup: errSecInteractionNotAllowed))
    }
}
