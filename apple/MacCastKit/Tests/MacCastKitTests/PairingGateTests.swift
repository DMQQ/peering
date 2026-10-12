import Foundation
import Testing

@testable import MacCastKit

struct PairingGateTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func theFirstSessionGetsThePrompt() {
        var gate = PairingGate()
        let first = UUID()
        #expect(gate.claim(session: first, address: "10.0.0.2", now: start) == nil)
        #expect(gate.holds(first))
    }

    @Test func aSecondSessionIsRefusedWhileTheFirstHoldsThePrompt() {
        var gate = PairingGate()
        let first = UUID()
        let second = UUID()
        _ = gate.claim(session: first, address: "10.0.0.2", now: start)

        #expect(gate.claim(session: second, address: "10.0.0.3", now: start) == .anotherPairingInProgress)
        #expect(!gate.holds(second))
        #expect(gate.holds(first))
    }

    @Test func approvalBelongsOnlyToTheHolder() {
        var gate = PairingGate()
        let first = UUID()
        _ = gate.claim(session: first, address: "10.0.0.2", now: start)

        #expect(!gate.holds(UUID()))
        #expect(gate.holds(first))
    }

    @Test func releasingFreesThePromptForTheNextSession() {
        var gate = PairingGate()
        let first = UUID()
        let second = UUID()
        _ = gate.claim(session: first, address: "10.0.0.2", now: start)

        #expect(gate.release(session: first) == true)
        #expect(gate.claim(session: second, address: "10.0.0.3", now: start) == nil)
    }

    @Test func aSessionThatNeverHeldThePromptCannotReleaseIt() {
        var gate = PairingGate()
        let first = UUID()
        _ = gate.claim(session: first, address: "10.0.0.2", now: start)

        #expect(gate.release(session: UUID()) == false)
        #expect(gate.holds(first))
    }

    @Test func claimingAgainAsTheHolderIsNotACountedAttempt() {
        var limits = PairingGate.Limits()
        limits.attemptsPerAddress = 1
        var gate = PairingGate(limits: limits)
        let first = UUID()

        #expect(gate.claim(session: first, address: "10.0.0.2", now: start) == nil)
        #expect(gate.claim(session: first, address: "10.0.0.2", now: start) == nil)
    }

    @Test func oneAddressIsLimitedWithinTheWindowAndFreedAfterIt() {
        var gate = PairingGate()
        for attempt in 0..<3 {
            let session = UUID()
            #expect(gate.claim(session: session, address: "10.0.0.2", now: start.addingTimeInterval(Double(attempt))) == nil)
            gate.release(session: session)
        }

        #expect(gate.claim(session: UUID(), address: "10.0.0.2", now: start.addingTimeInterval(5)) == .tooManyAttempts)
        let other = UUID()
        #expect(gate.claim(session: other, address: "10.0.0.9", now: start.addingTimeInterval(5)) == nil)
        gate.release(session: other)

        let afterWindow = start.addingTimeInterval(120)
        #expect(gate.claim(session: UUID(), address: "10.0.0.2", now: afterWindow) == nil)
    }

    @Test func allAddressesTogetherAreLimited() {
        var limits = PairingGate.Limits()
        limits.attemptsInTotal = 2
        var gate = PairingGate(limits: limits)

        for index in 0..<2 {
            let session = UUID()
            #expect(gate.claim(session: session, address: "10.0.0.\(index)", now: start) == nil)
            gate.release(session: session)
        }
        #expect(gate.claim(session: UUID(), address: "10.0.0.7", now: start) == .tooManyAttempts)
    }

    @Test func aHolderThatKeepsThePromptTooLongIsEvicted() {
        var gate = PairingGate()
        let first = UUID()
        _ = gate.claim(session: first, address: "10.0.0.2", now: start)

        #expect(gate.evictStaleHolder(now: start.addingTimeInterval(100)) == nil)
        #expect(gate.evictStaleHolder(now: start.addingTimeInterval(200)) == first)
        #expect(!gate.holds(first))
        #expect(gate.claim(session: UUID(), address: "10.0.0.3", now: start.addingTimeInterval(200)) == nil)
    }

    @Test func aClientReusingADeviceNameStillGetsItsOwnIdentity() {
        var gate = PairingGate()
        let real = UUID()
        let impostor = UUID()
        _ = gate.claim(session: real, address: "10.0.0.2", now: start)

        #expect(gate.claim(session: impostor, address: "10.0.0.66", now: start) == .anotherPairingInProgress)
        #expect(gate.release(session: impostor) == false)
        #expect(gate.holds(real))
    }
}
