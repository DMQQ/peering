import Testing

@testable import PeeringKit

@Suite("A new display layer")
struct VideoLayerReattachTests {
    @Test("a running stream with a keyframe repaints the new layer and asks for a fresh keyframe")
    func repaintsALiveStream() {
        #expect(VideoLayerReattach.action(hasKeyframe: true, streamIsLive: true) == .showKeyframeAndAskForFresh)
    }

    @Test("with no keyframe to show there is nothing to repaint")
    func noKeyframe() {
        #expect(VideoLayerReattach.action(hasKeyframe: false, streamIsLive: true) == .nothing)
    }

    @Test("a stream reconfigured and not yet drawing is left to its own keyframe")
    func streamNotLive() {
        #expect(VideoLayerReattach.action(hasKeyframe: true, streamIsLive: false) == .nothing)
        #expect(VideoLayerReattach.action(hasKeyframe: false, streamIsLive: false) == .nothing)
    }
}
