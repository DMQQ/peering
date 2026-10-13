import Testing

@testable import PeeringKit

@Suite("Pacing the capture stream")
struct StreamPacingTests {
    @Test("a request below the start rate lowers the stream")
    func lowersBelowTheBase() {
        #expect(StreamPacing.streamRate(requested: 30, base: 60) == 30)
    }

    @Test("a request at or above the start rate restores it")
    func restoresAtTheBase() {
        #expect(StreamPacing.streamRate(requested: 60, base: 60) == 60)
        #expect(StreamPacing.streamRate(requested: 120, base: 60) == 60)
    }

    @Test("no request, or a nonsense one, leaves the start rate")
    func ignoresMissingRequests() {
        #expect(StreamPacing.streamRate(requested: nil, base: 60) == 60)
        #expect(StreamPacing.streamRate(requested: 0, base: 60) == 60)
        #expect(StreamPacing.streamRate(requested: -5, base: 60) == 60)
    }

    @Test("an interval of one over sixty reads as sixty frames a second")
    func readsAnInterval() {
        #expect(StreamPacing.rate(intervalValue: 1, intervalTimescale: 60) == 60)
        #expect(StreamPacing.rate(intervalValue: 1001, intervalTimescale: 30000) == 30)
    }

    @Test("an unset interval has no rate")
    func unsetInterval() {
        #expect(StreamPacing.rate(intervalValue: 0, intervalTimescale: 0) == nil)
        #expect(StreamPacing.rate(intervalValue: 1, intervalTimescale: 0) == nil)
    }
}
