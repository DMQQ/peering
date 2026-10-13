import Foundation
import Testing

@testable import PeeringKit

@Suite("URL command gate")
struct URLCommandGateTests {
    private func unlocked() -> URLCommandGate {
        var gate = URLCommandGate()
        _ = gate.setLocked(false)
        return gate
    }

    @Test("a command arriving before the lock is lifted is held, then returned on unlock")
    func heldUntilUnlock() {
        var gate = URLCommandGate()
        #expect(gate.submit(.endShells, hasLiveSession: false, hasLiveShells: true) == nil)
        #expect(gate.confirming == nil)
        #expect(gate.setLocked(false) == .endShells)
        #expect(gate.setLocked(false) == nil)
    }

    @Test("an ending command asks first and runs only when confirmed")
    func confirmRuns() {
        var gate = unlocked()
        #expect(gate.submit(.disconnect, hasLiveSession: true, hasLiveShells: false) == nil)
        #expect(gate.confirming == .disconnect)
        #expect(gate.confirm() == .disconnect)
        #expect(gate.confirming == nil)
    }

    @Test("the lock coming up clears a pending confirmation so it cannot be accepted behind the lock")
    func lockClearsConfirmation() {
        var gate = unlocked()
        _ = gate.submit(.disconnect, hasLiveSession: true, hasLiveShells: false)
        _ = gate.setLocked(true)
        #expect(gate.confirming == nil)
        #expect(gate.confirm() == nil)
    }

    @Test("a command confirmed after the lock came up performs nothing and is not held")
    func confirmWhileLockedPerformsNothing() {
        var gate = unlocked()
        _ = gate.submit(.endShells, hasLiveSession: false, hasLiveShells: true)
        _ = gate.setLocked(true)
        #expect(gate.confirm() == nil)
        #expect(gate.setLocked(false) == nil)
    }

    @Test("cancelling drops the confirmation")
    func cancel() {
        var gate = unlocked()
        _ = gate.submit(.endShells, hasLiveSession: false, hasLiveShells: true)
        gate.cancelConfirmation()
        #expect(gate.confirm() == nil)
    }
}
