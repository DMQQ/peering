import PeeringKit
import Testing

@Suite struct TrackpadSwipeTests {
    @Test func aShortLiftIsNoSwipe() {
        #expect(TrackpadSwipe(dx: 20, dy: -10) == nil)
    }

    @Test func theLongerAxisDecides() {
        #expect(TrackpadSwipe(dx: -80, dy: 30) == .left)
        #expect(TrackpadSwipe(dx: 90, dy: -40) == .right)
        #expect(TrackpadSwipe(dx: 10, dy: -70) == .up)
        #expect(TrackpadSwipe(dx: -20, dy: 60) == .down)
    }
}
