import Testing
@testable import MacCastKit

@Suite struct PushRegistrationBackoffTests {
    @Test func delaysGrowWithEachFailure() {
        var backoff = PushRegistrationBackoff()
        #expect(backoff.failed() == 5)
        #expect(backoff.failed() == 30)
        #expect(backoff.failed() == 120)
        #expect(backoff.failed() == 600)
    }

    @Test func theLastDelayRepeats() {
        var backoff = PushRegistrationBackoff()
        for _ in 0..<4 { _ = backoff.failed() }
        #expect(backoff.failed() == 600)
        #expect(backoff.failed() == 600)
    }

    @Test func aTokenStartsTheLadderOver() {
        var backoff = PushRegistrationBackoff()
        _ = backoff.failed()
        _ = backoff.failed()
        backoff.succeeded()
        #expect(backoff.failed() == 5)
    }
}
