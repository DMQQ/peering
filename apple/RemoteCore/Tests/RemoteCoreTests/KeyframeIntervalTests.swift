import Testing

@testable import RemoteCore

struct KeyframeIntervalTests {
    @Test func theSafetyNetIntervalIsLongerThanAViewersRecoveryWindow() {
        // A viewer asks after 0.3 s of dropped frames and again no sooner than a second later, so any interval above a few seconds leaves recovery to the request.
        #expect(KeyframeInterval.seconds >= 5)
    }
}
