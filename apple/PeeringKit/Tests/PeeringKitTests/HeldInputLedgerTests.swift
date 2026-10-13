import RemoteCore
import Testing

@testable import MacCastKit

struct HeldInputLedgerTests {
    @Test func aHeldButtonIsReleasedOnLeaving() {
        var ledger = HeldInputLedger()
        ledger.observe(.mouseDown(button: .left))
        #expect(ledger.releaseCommands() == [.mouseUp(button: .left)])
        #expect(ledger.isEmpty)
    }

    @Test func aButtonThatWasLetGoIsNotReleasedAgain() {
        var ledger = HeldInputLedger()
        ledger.observe(.mouseDown(button: .left))
        ledger.observe(.mouseUp(button: .left))
        #expect(ledger.releaseCommands().isEmpty)
    }

    @Test func aHeldKeyIsReleasedBeforeTheButtons() {
        var ledger = HeldInputLedger()
        ledger.observe(.mouseDown(button: .right))
        ledger.observe(.keyDown(keyCode: 55, modifiers: [.command]))
        #expect(ledger.releaseCommands() == [
            .keyUp(keyCode: 55, modifiers: []),
            .mouseUp(button: .right),
        ])
    }

    @Test func aRepeatedPressIsReleasedOnce() {
        var ledger = HeldInputLedger()
        ledger.observe(.keyDown(keyCode: 12, modifiers: []))
        ledger.observe(.keyDown(keyCode: 12, modifiers: []))
        #expect(ledger.releaseCommands().count == 1)
    }

    @Test func commandsThatPressNothingLeaveTheLedgerEmpty() {
        var ledger = HeldInputLedger()
        ledger.observe(.mouseMove(to: NormalizedPoint(x: 0.5, y: 0.5)))
        ledger.observe(.scroll(dx: 0, dy: 1))
        #expect(ledger.isEmpty)
    }
}
