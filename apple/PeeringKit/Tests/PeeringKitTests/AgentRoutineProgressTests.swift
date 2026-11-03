import Foundation
import PeeringKit
import RemoteCore
import Testing

struct AgentRoutineProgressTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func aWorkingChatIsStillRunning() {
        let progress = AgentRoutineProgress.of(state: .working, finishedOK: nil, startedAt: start, now: start + 60, stopAfterMinutes: nil)
        #expect(progress == .running)
    }

    @Test func anIdleChatAfterAGoodTurnSucceeded() {
        let progress = AgentRoutineProgress.of(state: .idle, finishedOK: true, startedAt: start, now: start + 60, stopAfterMinutes: nil)
        #expect(progress == .ended(.succeeded))
    }

    @Test func anIdleChatBeforeItsFirstTurnIsGivenTimeToStart() {
        #expect(AgentRoutineProgress.of(state: .idle, finishedOK: nil, startedAt: start, now: start + 5, stopAfterMinutes: nil) == .running)
        #expect(AgentRoutineProgress.of(state: .idle, finishedOK: nil, startedAt: start, now: start + 601, stopAfterMinutes: nil) == .ended(.failed))
    }

    @Test func aFailedChatFailed() {
        let progress = AgentRoutineProgress.of(state: .failed, finishedOK: nil, startedAt: start, now: start + 60, stopAfterMinutes: nil)
        #expect(progress == .ended(.failed))
    }

    @Test func aClosedChatEndsTheRunAsStopped() {
        let progress = AgentRoutineProgress.of(state: nil, finishedOK: nil, startedAt: start, now: start + 60, stopAfterMinutes: nil)
        #expect(progress == .ended(.stopped))
    }

    @Test func aTurnPastItsLimitIsStopped() {
        let progress = AgentRoutineProgress.of(state: .awaitingApproval, finishedOK: nil, startedAt: start, now: start + 1_800, stopAfterMinutes: 30)
        #expect(progress == .overTime)
    }

    @Test func aTurnThatFinishedInsideItsLimitKeepsItsOutcome() {
        let progress = AgentRoutineProgress.of(state: .idle, finishedOK: true, startedAt: start, now: start + 1_800, stopAfterMinutes: 30)
        #expect(progress == .ended(.succeeded))
    }
}
