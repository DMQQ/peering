import Testing
@testable import RemoteCore

@Suite struct ClientStateNoticeTests {
    @Test func aNoticeAskedForBeforeTheSessionIsReadyGoesWhenItBecomesReady() {
        var notice = ClientStateNotice()
        notice.want(true)
        #expect(notice.takePending(isReady: false) == nil)
        #expect(notice.takePending(isReady: true) == true)
    }

    @Test func aStateTheMacAlreadyHasIsNotSentAgain() {
        var notice = ClientStateNotice()
        notice.want(true)
        _ = notice.takePending(isReady: true)
        #expect(notice.takePending(isReady: true) == nil)
        notice.want(false)
        #expect(notice.takePending(isReady: true) == false)
    }

    @Test func foregroundIsTheDefaultSoNothingIsSentForIt() {
        var notice = ClientStateNotice()
        #expect(notice.takePending(isReady: true) == nil)
    }

    @Test func aNewSessionIsToldAgainWhatTheAppStillWants() {
        var notice = ClientStateNotice()
        notice.want(true)
        _ = notice.takePending(isReady: true)
        notice.startOver()
        #expect(notice.takePending(isReady: true) == true)
    }

    @Test func returningBeforeTheSessionIsReadySendsNothing() {
        var notice = ClientStateNotice()
        notice.want(true)
        notice.want(false)
        #expect(notice.takePending(isReady: true) == nil)
    }
}
