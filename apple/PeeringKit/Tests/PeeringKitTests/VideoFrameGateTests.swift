import Foundation
import Testing

@testable import PeeringKit

@Suite("Video frame gate")
struct VideoFrameGateTests {
    @Test("a delta frame with nothing to decode against is dropped")
    func deltaWhileAwaiting() {
        #expect(VideoFrameGate.admit(isKeyframe: false, awaitingKeyframe: true, rendererReady: true) == .drop)
    }

    @Test("a delta frame the renderer has no room for re-arms the wait for a keyframe")
    func deltaWithNoRoom() {
        #expect(VideoFrameGate.admit(isKeyframe: false, awaitingKeyframe: false, rendererReady: false) == .dropAndAwaitKeyframe)
    }

    @Test("a keyframe at a backed-up renderer flushes it rather than waiting")
    func keyframeWithNoRoom() {
        #expect(VideoFrameGate.admit(isKeyframe: true, awaitingKeyframe: false, rendererReady: false) == .flushThenEnqueue)
        #expect(VideoFrameGate.admit(isKeyframe: true, awaitingKeyframe: true, rendererReady: false) == .flushThenEnqueue)
    }

    @Test("a keyframe or an expected delta is enqueued when there is room")
    func normal() {
        #expect(VideoFrameGate.admit(isKeyframe: true, awaitingKeyframe: true, rendererReady: true) == .enqueue)
        #expect(VideoFrameGate.admit(isKeyframe: false, awaitingKeyframe: false, rendererReady: true) == .enqueue)
    }
}
