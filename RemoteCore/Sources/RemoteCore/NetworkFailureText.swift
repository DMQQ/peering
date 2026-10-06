import Foundation
import Network

/// An `NWError` is not a `LocalizedError`: `localizedDescription` gives `Network.NWError error 60`, a type name and number nobody can act on. Used by both transport and session so neither leaks the raw error.
public enum NetworkFailureText {
    public static func describe(_ error: Error) -> String {
        guard let nwError = error as? NWError, case .posix(let code) = nwError else {
            return (error as? LocalizedError)?.errorDescription ?? "The connection to the Mac failed."
        }
        return describe(code)
    }

    public static func describe(_ code: POSIXErrorCode) -> String {
        switch code {
        // 54 is the common one: the other end went away without closing (host quit, app rebuilt, Mac slept). Must not imply it is the phone's fault.
        case .ECONNRESET:
            return "The Mac closed the connection. It may have quit, restarted, or gone to sleep."
        case .ECONNREFUSED:
            return "The Mac refused the connection. Check that Peering is running on it."
        case .ETIMEDOUT:
            return "The Mac did not answer. Check that both devices are on the same network."
        case .EHOSTUNREACH, .ENETUNREACH:
            return "The Mac could not be reached on this network."
        case .EPIPE:
            return "The connection to the Mac was lost."
        case .ENETDOWN:
            return "This device is not on a network."
        case .EADDRNOTAVAIL, .EADDRINUSE:
            return "This device could not open the connection it needs."
        case .ECONNABORTED:
            return "The connection to the Mac was interrupted."
        case .EHOSTDOWN:
            return "The Mac is switched off or asleep."
        default:
            // Without the code: the user cannot act on it, and it is in the log.
            return "The connection to the Mac failed."
        }
    }
}
