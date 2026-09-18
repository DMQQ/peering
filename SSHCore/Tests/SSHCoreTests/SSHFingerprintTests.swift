import Foundation
import Testing

@testable import SSHCore

/// The one test in this package that is checked against something outside it.
///
/// The vector below is a real ed25519 key, and the expected string is what
/// `ssh-keygen -lf` prints for it:
///
/// ```
/// $ ssh-keygen -lf /tmp/testkey.pub
/// 256 SHA256:iP10HXLu5DtrSwVVy/XGGu12zRkT9/+Wahc6Jh9mKA4 peering-fingerprint-test (ED25519)
/// ```
///
/// It is spelled out rather than computed because the *only* reason the app shows a fingerprint is
/// so somebody can compare it with what their server reports by another route. An implementation
/// that hashes the right things in the wrong order, or keeps the base64 padding OpenSSH strips,
/// produces a string that looks exactly like a fingerprint and matches nothing — and the screen it
/// appears on teaches people to tap through it. This test is what stops that.
@Suite("Fingerprint")
struct SSHFingerprintTests {
    /// The base64 of the whole public key blob: algorithm name, its length prefix, and the key.
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
