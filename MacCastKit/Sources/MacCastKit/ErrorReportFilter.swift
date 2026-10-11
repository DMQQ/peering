import Foundation

/// Which handled errors are worth an Error Tracking issue: not the ones that only say the network is down, and not the same one twice.
public struct ErrorReportFilter: Sendable {
    private var reported: Set<String> = []

    public init() {}

    /// An offline device or a dropped socket is the connection's state, not a defect: it arrived as 361 occurrences from one retry loop.
    public static func isNetworkWeather(domain: String, code: Int) -> Bool {
        switch domain {
        case NSURLErrorDomain:
            return [
                NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
                NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed, NSURLErrorCancelled,
            ].contains(code)
        case NSPOSIXErrorDomain:
            return [
                Int(ENETDOWN), Int(ENETUNREACH), Int(ECONNABORTED), Int(ECONNRESET), Int(ENOTCONN),
                Int(ETIMEDOUT), Int(ECONNREFUSED), Int(EHOSTDOWN), Int(EHOSTUNREACH), Int(EPIPE), Int(ECANCELED),
            ].contains(code)
        default:
            return false
        }
    }

    /// ScreenCaptureKit's own recoverable states: `-3801` is Screen Recording not granted and `-3821` is the system stopping a stream after a display change or wake. The host handles both and tells the phone, so neither is a defect to track.
    public static func isExpectedCaptureState(domain: String, code: Int) -> Bool {
        domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && [-3801, -3821].contains(code)
    }

    /// The system declining to run a feature right now, which the app already handles by carrying on without it: a Live Activity the system will not persist or show (`denied`, the activity limits, `visibility`, `persistenceFailure`), audio that cannot start while another app holds the session (`!pla`), and the App Store saying it cannot be reached or the person backed out. Codes are `ActivityAuthorizationError` 2, 3, 4, 6, 7 and `StoreKitError` 1, 2, 3.
    public static func isSystemDeclining(domain: String, code: Int) -> Bool {
        switch domain {
        case "com.apple.ActivityKit.ActivityAuthorization": return [2, 3, 4, 6, 7].contains(code)
        case NSOSStatusErrorDomain: return code == 0x2170_6C61
        case "StoreKit.StoreKitError": return [1, 2, 3].contains(code)
        default: return false
        }
    }

    /// False for network weather, including when it is the underlying cause of a wrapper such as Sparkle's, and for a failure already reported since launch.
    public mutating func shouldReport(_ error: NSError, area: String) -> Bool {
        var current: NSError? = error
        while let link = current {
            if Self.isNetworkWeather(domain: link.domain, code: link.code)
                || Self.isExpectedCaptureState(domain: link.domain, code: link.code)
                || Self.isSystemDeclining(domain: link.domain, code: link.code) { return false }
            current = link.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return reported.insert("\(area)|\(error.domain)|\(error.code)").inserted
    }
}
