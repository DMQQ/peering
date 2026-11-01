import Foundation
import Testing
import RemoteCore

@testable import PeeringKit

@Suite("Which handled errors are reported")
struct ErrorReportFilterTests {
    @Test("being offline is not reported")
    func offlineIsWeather() {
        var filter = ErrorReportFilter()
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let r1 = filter.shouldReport(offline, area: "relay")
        #expect(!r1)
    }

    @Test("a socket that is not connected is not reported")
    func socketNotConnected() {
        var filter = ErrorReportFilter()
        let r2 = filter.shouldReport(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN)), area: "relay")
        #expect(!r2)
    }

    @Test("a reset connection is weather, also under a wrapper")
    func resetIsWeatherThroughWrappers() {
        let reset = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        let wrapped = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: reset])
        #expect(ErrorReportFilter.isNetworkWeather(reset))
        #expect(ErrorReportFilter.isNetworkWeather(wrapped))
        #expect(!ErrorReportFilter.isNetworkWeather(NSError(domain: "Wrapper", code: 1)))
    }

    @Test("a wrapper over a network failure is not reported")
    func wrappedNetworkFailure() {
        var filter = ErrorReportFilter()
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let wrapper = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSUnderlyingErrorKey: underlying])
        let r3 = filter.shouldReport(wrapper, area: "update")
        #expect(!r3)
    }

    @Test("a real failure is reported once per area")
    func reportedOnce() {
        var filter = ErrorReportFilter()
        let failure = NSError(domain: "com.apple.ActivityKit.ActivityAuthorization", code: 0)
        let r4 = filter.shouldReport(failure, area: "liveActivity")
        #expect(r4)
        let r5 = filter.shouldReport(failure, area: "liveActivity")
        #expect(!r5)
        let r6 = filter.shouldReport(failure, area: "audio")
        #expect(r6)
    }

    @Test("Screen Recording not granted is a handled state, not a defect")
    func screenRecordingDeclined() {
        var filter = ErrorReportFilter()
        let declined = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
        let r7 = filter.shouldReport(declined, area: "capture")
        #expect(!r7)
    }

    @Test("the system declining a Live Activity, audio or the App Store is not reported")
    func systemDeclining() {
        var filter = ErrorReportFilter()
        let persistence = NSError(domain: "com.apple.ActivityKit.ActivityAuthorization", code: 7)
        let audio = NSError(domain: NSOSStatusErrorDomain, code: 561_015_905)
        let store = NSError(domain: "StoreKit.StoreKitError", code: 3)
        let r8 = filter.shouldReport(persistence, area: "liveActivity")
        let r9 = filter.shouldReport(audio, area: "audio")
        let r10 = filter.shouldReport(store, area: "purchase")
        #expect(!r8)
        #expect(!r9)
        #expect(!r10)
    }

    @Test("an oversized Live Activity is still reported")
    func attributesTooLargeIsReported() {
        var filter = ErrorReportFilter()
        let tooLarge = NSError(domain: "com.apple.ActivityKit.ActivityAuthorization", code: 0)
        let r11 = filter.shouldReport(tooLarge, area: "liveActivity")
        #expect(r11)
    }

    @Test("a launch stops reporting once its budget is spent, even for new codes")
    func launchBudget() {
        var filter = ErrorReportFilter()
        var accepted = 0
        for code in 1...(ErrorReportFilter.reportsPerLaunch + 10) {
            if filter.shouldReport(NSError(domain: "Sample", code: code), area: "relay") { accepted += 1 }
        }
        #expect(accepted == ErrorReportFilter.reportsPerLaunch)
    }

    @Test("an address that cannot be assigned after a network change is weather")
    func addressNotAvailableIsWeather() {
        var filter = ErrorReportFilter()
        let reported = filter.shouldReport(NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRNOTAVAIL)), area: "relay")
        #expect(!reported)
    }

    @Test("audio another app holds is the system declining, whichever way it says so")
    func audioHeldElsewhere() {
        var filter = ErrorReportFilter()
        let priority = filter.shouldReport(NSError(domain: NSOSStatusErrorDomain, code: 561017449), area: "audio")
        let interrupt = filter.shouldReport(NSError(domain: NSOSStatusErrorDomain, code: 560557684), area: "audio")
        #expect(!priority)
        #expect(!interrupt)
    }

    @Test("a Mac the relay reports offline or a relay timing out is not a defect, any other relay error is")
    func relayStatesBridgedFromRealCases() {
        var filter = ErrorReportFilter()
        let offline = filter.shouldReport(RelaySignallingError.hostOffline("mac") as NSError, area: "relay")
        let timedOut = filter.shouldReport(RelaySignallingError.timedOut as NSError, area: "relay")
        let refused = filter.shouldReport(RelaySignallingError.refused(code: "x", message: "y") as NSError, area: "relay")
        let nonWebSocket = filter.shouldReport(RelaySignallingError.nonWebSocketResponse as NSError, area: "relay")
        let unexpected = filter.shouldReport(RelaySignallingError.unexpectedResponse as NSError, area: "relay")
        #expect(!offline)
        #expect(!timedOut)
        #expect(refused)
        #expect(nonWebSocket)
        #expect(unexpected)
    }

    @Test("a failed secure connection is the person's network, not a defect, also under a wrapper")
    func secureConnectionFailure() {
        var filter = ErrorReportFilter()
        let tls = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        let wrapped = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: tls])
        #expect(ErrorReportFilter.isSecureConnectionFailure(wrapped))
        #expect(!ErrorReportFilter.isSecureConnectionFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)))
        let reported = filter.shouldReport(tls, area: "relay")
        #expect(!reported)
    }
}
