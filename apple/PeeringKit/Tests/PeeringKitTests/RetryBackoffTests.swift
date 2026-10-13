import Testing

@testable import MacCastKit

@Suite("Retrying with backoff")
struct RetryBackoffTests {
    @Test func delaysDoubleFromTheFirst() {
        let backoff = RetryBackoff(firstDelay: .seconds(2), ceiling: .seconds(60), maximumRetries: 4)
        #expect(backoff.delay(beforeRetry: 0) == .seconds(2))
        #expect(backoff.delay(beforeRetry: 1) == .seconds(4))
        #expect(backoff.delay(beforeRetry: 2) == .seconds(8))
    }

    @Test func aDelayNeverPassesTheCeiling() {
        let backoff = RetryBackoff(firstDelay: .seconds(10), ceiling: .seconds(15), maximumRetries: 5)
        #expect(backoff.delay(beforeRetry: 3) == .seconds(15))
    }

    @Test func retriesRunOut() {
        let backoff = RetryBackoff(maximumRetries: 2)
        #expect(backoff.delay(beforeRetry: 1) != nil)
        #expect(backoff.delay(beforeRetry: 2) == nil)
    }
}
