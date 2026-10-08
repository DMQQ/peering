import Crypto
import Foundation

/// Must be byte-identical to `ssh-keygen -lf`, or the user cannot check it by another route: `SHA256:` then base64 of the SHA-256 of the whole public key blob, with the `=` padding removed (where OpenSSH departs from base64).
public enum SSHFingerprint {
    public static func string(of publicKeyBlob: Data) -> String {
        let digest = SHA256.hash(data: publicKeyBlob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    public static func digest(of publicKeyBlob: Data) -> Data {
        Data(SHA256.hash(data: publicKeyBlob))
    }
}
