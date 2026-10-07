#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Network
import Security

/// ```
/// what an endpoint sends:   [ token 16 ][ counter 8 ][ ciphertext ][ tag 16 ]
/// what an endpoint gets:    [           counter 8 ][ ciphertext ][ tag 16 ]
/// ```
/// The relay strips the token before forwarding: it exists to tell the relay which session a datagram
/// belongs to and which end sent it, and is dead weight afterwards. An opener that expected one would
/// read the first eight bytes of a counter as somebody's identity.
/// A datagram that is only the token is a bind: it registers the sender's address with the relay
/// and is not forwarded. Both ends send one.
public enum VideoDatagram {
    public static let tokenSize = 16
    public static let counterSize = 8
    public static let tagSize = 16

    public static let minForwardedSize = counterSize + tagSize

    public static let maxDatagramSize = 2 * 1024
}
