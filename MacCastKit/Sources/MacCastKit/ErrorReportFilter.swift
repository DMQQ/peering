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

    /// False for network weather, including when it is the underlying cause of a wrapper such as Sparkle's, and for a failure already reported since launch.
    public mutating func shouldReport(_ error: NSError, area: String) -> Bool {
        var current: NSError? = error
        while let link = current {
            if Self.isNetworkWeather(domain: link.domain, code: link.code)
                || Self.isExpectedCaptureState(domain: link.domain, code: link.code) { return false }
            current = link.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return reported.insert("\(area)|\(error.domain)|\(error.code)").inserted
    }
}
