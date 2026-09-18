import Crypto
import Foundation

/// The string you compare against `ssh-keygen -lf`.
///
/// This has to be *byte-identical* to what OpenSSH prints, and that is the whole feature rather
/// than a detail of it: the only reason to show a fingerprint is that the user can check it
/// against the server by some other route — the VPS console, a colleague, the documentation they
/// set it up from. A fingerprint that is merely "a hash of something" is one nobody can check, and
/// one nobody can check is one everybody learns to tap through, which leaves a screen that costs a
/// tap and buys nothing.
///
/// So: `SHA256:` then the standard base64 of the SHA-256 of the *whole public key blob* — the
/// algorithm name, its length prefix, and the key material — with the padding `=` removed, which is
/// the one place OpenSSH departs from base64 and the one place an implementation is likely to
/// differ from it.
public enum SSHFingerprint {
    public static func string(of publicKeyBlob: Data) -> String {
        let digest = SHA256.hash(data: publicKeyBlob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Hash and fingerprint both, for a test that wants to check the halves separately.
    public static func digest(of publicKeyBlob: Data) -> Data {
        Data(SHA256.hash(data: publicKeyBlob))
    }
}
