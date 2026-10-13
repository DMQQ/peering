import Foundation
import Network

/// An `NWError` is not a `LocalizedError`: `localizedDescription` gives `Network.NWError error 60`, a type name and number nobody can act on. Used by both transport and session so neither leaks the raw error.
public enum NetworkFailureText {
    /// What went wrong on the wire, from a closed set, so the app can word it in the user's language.
    public enum Kind: Sendable, Equatable, CaseIterable {
        case connectionReset, connectionRefused, notAnswering, unreachable, connectionLost
        case noNetwork, cannotOpen, interrupted, hostDown, failed
    }

    public static func describe(_ error: Error) -> String {
        guard let nwError = error as? NWError else {
            return (error as? LocalizedError)?.errorDescription ?? sentence(for: .failed)
        }
        return sentence(for: kind(of: nwError))
    }

    public static func describe(_ code: POSIXErrorCode) -> String {
        sentence(for: kind(of: code))
    }

    public static func kind(of error: NWError) -> Kind {
        guard case .posix(let code) = error else { return .failed }
        return kind(of: code)
    }

    public static func kind(of code: POSIXErrorCode) -> Kind {
        switch code {
        // 54 is the common one: the other end went away without closing (host quit, app rebuilt, Mac slept). Must not imply it is the phone's fault.
        case .ECONNRESET: return .connectionReset
        case .ECONNREFUSED: return .connectionRefused
        case .ETIMEDOUT: return .notAnswering
        case .EHOSTUNREACH, .ENETUNREACH: return .unreachable
        case .EPIPE: return .connectionLost
        case .ENETDOWN: return .noNetwork
        case .EADDRNOTAVAIL, .EADDRINUSE: return .cannotOpen
        case .ECONNABORTED: return .interrupted
        case .EHOSTDOWN: return .hostDown
        default: return .failed
        }
    }

    /// English, for logs and for a peer that cannot be asked for its language. The app words each kind itself.
    public static func sentence(for kind: Kind) -> String {
        switch kind {
        case .connectionReset: return "The Mac closed the connection. It may have quit, restarted, or gone to sleep."
        case .connectionRefused: return "The Mac refused the connection. Check that Peering is running on it."
        case .notAnswering: return "The Mac did not answer. Check that both devices are on the same network."
        case .unreachable: return "The Mac could not be reached on this network."
        case .connectionLost: return "The connection to the Mac was lost."
        case .noNetwork: return "This device is not on a network."
        case .cannotOpen: return "This device could not open the connection it needs."
        case .interrupted: return "The connection to the Mac was interrupted."
        case .hostDown: return "The Mac is switched off or asleep."
        // Without the code: the user cannot act on it, and it is in the log.
        case .failed: return "The connection to the Mac failed."
        }
    }
}
