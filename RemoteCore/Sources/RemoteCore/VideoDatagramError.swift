import CryptoKit
import Crypto
import Foundation
import Network
import Security

public enum VideoDatagramError: Error, Equatable, Sendable {
    case truncated(have: Int, need: Int)
    /// An error rather than a dropped packet: this is the one signal that distinguishes the network
    /// losing video from two ends not speaking the same key, and swallowing it would leave a session
    /// with no picture and nothing to look at.
    case authenticationFailed
    case malformedPayload
    case invalidToken(bytes: Int)
    case invalidPort(UInt16)
    case oversized(bytes: Int)
    case unresolvedHost(String)
    case unusablePeerAddress(String)
    case socketUnavailable(Int32)
    case sendFailed(Int32)
    case socketReadFailed(Int32)
}

extension VideoDatagramError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unresolvedHost(let host): return "Could not resolve the relay's address (\(host))."
        case .unusablePeerAddress(let host): return "The peer's address is not usable from this socket (\(host))."
        case .socketUnavailable(let code): return "The video socket could not be opened (\(code))."
        case .sendFailed(let code): return "Sending a video datagram failed (\(code))."
        case .socketReadFailed(let code): return "Reading the video socket failed (\(code))."
        default: return nil
        }
    }
}
