import Foundation
import Testing

@testable import SSHCore

/// Spelled out rather than computed, since the fingerprint is only useful if it matches `ssh-keygen -lf`, here for a real ed25519 key:
/// ```
/// $ ssh-keygen -lf /tmp/testkey.pub
/// 256 SHA256:iP10HXLu5DtrSwVVy/XGGu12zRkT9/+Wahc6Jh9mKA4 peering-fingerprint-test (ED25519)
/// ```
@Suite("Fingerprint")
struct SSHFingerprintTests {
    static let ed25519Blob = Data(
        base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIPhGETf0Tawl2m8lQsZOblV+2iWtUwLqwXrN78kWqEAz"
    )!

    @Test("matches what ssh-keygen prints, byte for byte")
    func matchesOpenSSH() {
        #expect(SSHFingerprint.string(of: Self.ed25519Blob) == "SHA256:iP10HXLu5DtrSwVVy/XGGu12zRkT9/+Wahc6Jh9mKA4")
    }

    @Test("carries no base64 padding, which is the one place OpenSSH departs from base64")
    func hasNoPadding() {
        #expect(!SSHFingerprint.string(of: Self.ed25519Blob).contains("="))
    }

    @Test("a different key is a different fingerprint")
    func differsPerKey() {
        var changed = Self.ed25519Blob
        changed[changed.count - 1] ^= 0xFF
        #expect(SSHFingerprint.string(of: changed) != SSHFingerprint.string(of: Self.ed25519Blob))
    }

    @Test("two calls agree, so a stored fingerprint still matches on the next connect")
    func isStable() {
        #expect(SSHFingerprint.string(of: Self.ed25519Blob) == SSHFingerprint.string(of: Self.ed25519Blob))
    }
}
