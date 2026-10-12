import Foundation
import Testing

@testable import RemoteCore

@Suite("Back pressure on a long send")
struct SendWindowTests {
    @Test func admitsUntilTheLimitThenWaits() {
        var state = SendWindowState(limit: 100)
        #expect(state.reserve(60) == .admitted)
        #expect(state.reserve(40) == .admitted)
        #expect(state.reserve(1) == .wait)
    }

    @Test func completionMakesRoom() {
        var state = SendWindowState(limit: 100)
        _ = state.reserve(100)
        state.complete(50, errorText: nil)
        #expect(state.reserve(50) == .admitted)
    }

    @Test func aPieceLargerThanTheWindowStillGoesWhenNothingIsInFlight() {
        var state = SendWindowState(limit: 10)
        #expect(state.reserve(50) == .admitted)
        #expect(state.reserve(1) == .wait)
    }

    @Test func aSendErrorRefusesEveryLaterReservation() {
        var state = SendWindowState(limit: 100)
        _ = state.reserve(10)
        state.complete(10, errorText: "broken pipe")
        #expect(state.reserve(1) == .refused(SendWindowFailure.failed("broken pipe")))
    }

    @Test func cancellationIsDistinguishableFromAnError() {
        var state = SendWindowState(limit: 100)
        state.cancel()
        guard case .refused(let failure) = state.reserve(1) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(failure.isCancelled)
    }

    @Test func theFirstFailureIsTheOneKept() {
        var state = SendWindowState(limit: 100)
        state.complete(0, errorText: "first")
        state.complete(0, errorText: "second")
        #expect(state.failure == .failed("first"))
    }

    @Test func reservationWithinTheLimitReturnsWithoutWaiting() async throws {
        let window = SendWindow(limit: 100)
        try await window.reserve(60)
        try await window.reserve(40)
    }

    @Test func aReservationThatHadToWaitIsAdmittedOnceBytesComplete() async throws {
        let window = SendWindow(limit: 100)
        try await window.reserve(100)
        let waiting = Task { try await window.reserve(50) }
        window.complete(100, error: nil)
        try await waiting.value
    }

    @Test func cancellingTheWaitingTaskEndsTheWaitWithCancellationError() async throws {
        let window = SendWindow(limit: 10)
        try await window.reserve(10)
        let waiting = Task { try await window.reserve(5) }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test func aWindowCancelIsASendWindowFailureThatSaysCancelled() async throws {
        let window = SendWindow(limit: 10)
        window.cancel()
        await #expect(throws: SendWindowFailure.cancelled) { try await window.reserve(1) }
    }

    @Test func cancelFailsAWaitingReservation() async throws {
        let window = SendWindow(limit: 10)
        try await window.reserve(10)
        let waiting = Task { try await window.reserve(5) }
        window.cancel()
        await #expect(throws: SendWindowFailure.self) { try await waiting.value }
    }
}
