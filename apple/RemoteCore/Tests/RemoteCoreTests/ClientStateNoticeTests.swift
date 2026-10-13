import Testing
@testable import RemoteCore

@Suite struct ClientStateNoticeTests {
    @Test func aNoticeAskedForBeforeTheSessionIsReadyGoesWhenItBecomesReady() {
        var notice = ClientStateNotice()
        notice.want(true)
        #expect(notice.takePending(isReady: false, hostDeclared: true) == nil)
        #expect(notice.takePending(isReady: true, hostDeclared: true) == true)
    }

    @Test func aStateTheMacAlreadyHasIsNotSentAgain() {
        var notice = ClientStateNotice()
        notice.want(true)
        _ = notice.takePending(isReady: true, hostDeclared: true)
        #expect(notice.takePending(isReady: true, hostDeclared: true) == nil)
        notice.want(false)
        #expect(notice.takePending(isReady: true, hostDeclared: true) == false)
    }

    @Test func aHostThatDidNotDeclareTheNoticeIsNeverSentOne() {
        var notice = ClientStateNotice()
        notice.want(true)
        #expect(notice.takePending(isReady: true, hostDeclared: nil) == nil)
        #expect(notice.takePending(isReady: true, hostDeclared: false) == nil)
    }

    @Test func foregroundIsTheDefaultSoNothingIsSentForIt() {
        var notice = ClientStateNotice()
        #expect(notice.takePending(isReady: true, hostDeclared: true) == nil)
    }

    @Test func aNewSessionIsToldAgainWhatTheAppStillWants() {
        var notice = ClientStateNotice()
        notice.want(true)
        _ = notice.takePending(isReady: true, hostDeclared: true)
        notice.startOver()
        #expect(notice.takePending(isReady: true, hostDeclared: true) == true)
    }

    @Test func returningBeforeTheSessionIsReadySendsNothing() {
        var notice = ClientStateNotice()
        notice.want(true)
        notice.want(false)
        #expect(notice.takePending(isReady: true, hostDeclared: true) == nil)
    }
}
