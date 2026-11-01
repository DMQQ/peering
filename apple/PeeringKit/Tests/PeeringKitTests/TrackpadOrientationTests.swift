import PeeringKit
import Testing

@Suite struct TrackpadOrientationTests {
    @Test func aMatchingScreenLeavesMovementAlone() {
        let moved = TrackpadOrientation(device: 1, screen: 1).intended(dx: 3, dy: -2)
        #expect(moved.dx == 3)
        #expect(moved.dy == -2)
    }

    @Test func upsideDownReversesBothAxes() {
        let moved = TrackpadOrientation(device: 2, screen: 0).intended(dx: 3, dy: -2)
        #expect(moved.dx == -3)
        #expect(moved.dy == 2)
    }

    @Test func topToTheLeftTurnsDownTheGlassIntoRight() {
        let moved = TrackpadOrientation(device: 1, screen: 0).intended(dx: 0, dy: 5)
        #expect(moved.dx == 5)
        #expect(moved.dy == 0)
    }

    @Test func turnsWrapAround() {
        #expect(TrackpadOrientation(device: 0, screen: 1).quarterTurns == 3)
    }
}
