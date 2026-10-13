import Foundation
import Testing

@testable import PeeringKit

@Suite("Agent pause clock")
struct AgentPauseClockTests {
    private let id = UUID()
    private let began = Date(timeIntervalSince1970: 1_000)
    private let pausedMoment = Date(timeIntervalSince1970: 5_000)

    @Test("a chat seen running and then paused is dated from the pause")
    func pauseIsStamped() {
        var clock = AgentPauseClock()
        clock.observe(id, isPaused: false, at: began)
        clock.observe(id, isPaused: true, at: pausedMoment)

        #expect(clock.date(for: id, fallback: began) == pausedMoment)
    }

    @Test("a chat first seen already paused keeps the date it began")
    func alreadyPausedKeepsFallback() {
        var clock = AgentPauseClock()
        clock.observe(id, isPaused: true, at: pausedMoment)

        #expect(clock.date(for: id, fallback: began) == began)
    }

    @Test("a later observation does not move the stamp")
    func stampIsStable() {
        var clock = AgentPauseClock()
        clock.observe(id, isPaused: false, at: began)
        clock.observe(id, isPaused: true, at: pausedMoment)
        clock.observe(id, isPaused: true, at: pausedMoment.addingTimeInterval(900))

        #expect(clock.date(for: id, fallback: began) == pausedMoment)
    }

    @Test("picking a chat up again clears its stamp")
    func resumingClearsStamp() {
        var clock = AgentPauseClock()
        clock.observe(id, isPaused: false, at: began)
        clock.observe(id, isPaused: true, at: pausedMoment)
        clock.observe(id, isPaused: false, at: pausedMoment.addingTimeInterval(60))

        #expect(clock.date(for: id, fallback: began) == began)
    }
}
