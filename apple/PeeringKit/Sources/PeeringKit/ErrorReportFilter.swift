import Foundation
import RemoteCore

/// Which handled errors are worth an Error Tracking issue: not the ones that only say the network is down, and not the same one twice.
public struct ErrorReportFilter: Sendable {
    /// A loop that throws a different code each turn passes the per-error dedup, so the whole launch is capped as well.
    public static let reportsPerLaunch = 20

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
                Int(EADDRNOTAVAIL),
            ].contains(code)
        default:
            return false
        }
    }

    /// Whether the error, or anything it wraps, is network weather.
    public static func isNetworkWeather(_ error: NSError) -> Bool {
        var current: NSError? = error
        while let link = current {
            if isNetworkWeather(domain: link.domain, code: link.code) { return true }
            current = link.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// The handshake with the relay failing or its certificate not being trusted (-1200 to -1205). The relay's certificate is valid, so this is the person's network (a VPN, proxy or filter that intercepts TLS) or a wrong system clock: the host says so on its status line and the failure is counted in `host_error`, but it is not a defect to track.
    public static func isSecureConnectionFailure(domain: String, code: Int) -> Bool {
        domain == NSURLErrorDomain && (-1205 ... -1200).contains(code)
    }

    /// Whether the error, or anything it wraps, is a failed secure connection.
    public static func isSecureConnectionFailure(_ error: NSError) -> Bool {
        var current: NSError? = error
        while let link = current {
            if isSecureConnectionFailure(domain: link.domain, code: link.code) { return true }
            current = link.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// ScreenCaptureKit's own recoverable states: `-3801` is Screen Recording not granted and `-3821` is the system stopping a stream after a display change or wake. The host handles both and tells the phone, so neither is a defect to track.
    public static func isExpectedCaptureState(domain: String, code: Int) -> Bool {
        domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && [-3801, -3821].contains(code)
    }

    /// The system declining to run a feature right now, which the app already handles by carrying on without it: a Live Activity the system will not persist or show (`denied`, the activity limits, `visibility`, `persistenceFailure`), audio that cannot start while another app holds the session (`!pla`, `!pri`, `!int`), and the App Store saying it cannot be reached or the person backed out. Codes are `ActivityAuthorizationError` 2, 3, 4, 6, 7 and `StoreKitError` 1, 2, 3.
    public static func isSystemDeclining(domain: String, code: Int) -> Bool {
        switch domain {
        case "com.apple.ActivityKit.ActivityAuthorization": return [2, 3, 4, 6, 7].contains(code)
        case NSOSStatusErrorDomain: return [0x2170_6C61, 0x2170_7269, 0x2169_6E74].contains(code)
        case "StoreKit.StoreKitError": return [1, 2, 3].contains(code)
        default: return false
        }
    }

    /// The relay answering that the Mac is not registered (`hostOffline`) or not answering in time (`timedOut`): the other end's state, which the app already shows.
    public static func isExpectedRelayState(domain: String, code: Int) -> Bool {
        expectedRelayStates.contains { $0.domain == domain && $0.code == code }
    }

    /// Bridged from the real cases: Swift numbers payload cases before plain ones, so declaration order does not give the code.
    private static let expectedRelayStates: [NSError] = [
        RelaySignallingError.hostOffline("") as NSError,
        RelaySignallingError.timedOut as NSError,
    ]

    /// False for network weather, including when it is the underlying cause of a wrapper such as Sparkle's, for a failure already reported since launch, and once a launch has used its budget.
    public mutating func shouldReport(_ error: NSError, area: String) -> Bool {
        var current: NSError? = error
        while let link = current {
            if Self.isNetworkWeather(domain: link.domain, code: link.code)
                || Self.isExpectedCaptureState(domain: link.domain, code: link.code)
                || Self.isSystemDeclining(domain: link.domain, code: link.code)
                || Self.isExpectedRelayState(domain: link.domain, code: link.code)
                || Self.isSecureConnectionFailure(domain: link.domain, code: link.code) { return false }
            current = link.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        guard reported.count < Self.reportsPerLaunch else { return false }
        return reported.insert("\(area)|\(error.domain)|\(error.code)").inserted
    }
}
