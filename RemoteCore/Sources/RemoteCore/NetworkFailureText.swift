import Foundation
import Network

/// What to say to the user about an error that came from the network rather than from the protocol.
///
/// **`Network.framework` reports a POSIX failure as an `NWError`, and an `NWError` is not a
/// `LocalizedError`.** So `error.localizedDescription` on one falls through to `String(describing:)`
/// and hands back `Network.NWError error 60`: a type name and a number, in a notification, in front
/// of somebody who can do nothing with either. That is not a hypothetical: it is what a connection
/// that timed out used to say, because the transport built its failure out of `localizedDescription`
/// while the session built its own out of this.
///
/// **One function, called from both.** The transport and the session fail for the same reasons and
/// have the same thing to say about them, and two spellings of that is how one of them ends up
/// leaking the raw error again.
///
/// The codes here are the handful that actually occur when a phone talks to a Mac on a local
/// network. Anything else is a case nobody has seen, and it gets a plain sentence rather than an
/// enum name; the raw error belongs in the log, where it is useful, and not on screen, where it is
/// not.
public enum NetworkFailureText {
    /// A sentence for the user, and never the error's own description.
    ///
    /// `Error` rather than `NWError` because the caller has caught something and should not have to
    /// know what it is: anything that is not an `NWError` keeps whatever a `LocalizedError` says for
    /// itself, which is the app's own wording when the app is the one that failed.
    public static func describe(_ error: Error) -> String {
        guard let nwError = error as? NWError, case .posix(let code) = nwError else {
            return (error as? LocalizedError)?.errorDescription ?? "The connection to the Mac failed."
        }
        return describe(code)
    }

    /// A sentence for a POSIX code, for the callers that already have one.
    public static func describe(_ code: POSIXErrorCode) -> String {
        switch code {
        // 54 is the common one and the one worth getting right: it means the *other end* went
        // away without closing politely. The host quit, the app was rebuilt, the Mac slept. It
        // usually says nothing at all about the phone, and the message should not imply it does.
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
            // Deliberately without the code. A user cannot act on `error 65`, and the number is
            // already in the log next to the session it belongs to.
            return "The connection to the Mac failed."
        }
    }
}
