import Foundation
import Testing

@testable import MacCastKit

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
}
