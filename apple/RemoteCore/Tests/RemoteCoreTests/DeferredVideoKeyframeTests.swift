import Foundation
import Testing

@testable import RemoteCore

@Suite("A recovery frame held across video startup")
struct DeferredVideoKeyframeTests {
    private func frame(keyframe: Bool = true, width: Int = 100) -> EncodedVideoFrame {
        EncodedVideoFrame(
            isKeyframe: keyframe,
            pixelWidth: width,
            pixelHeight: 100,
            presentationTime: VideoTimestamp(value: 42, timescale: 60),
            data: Data([0, 0, 0, 1])
        )
    }

    private func config(width: Int = 100) -> VideoStreamConfig {
        VideoStreamConfig(
            sourceID: "display:1", codec: .h264, pixelWidth: width, pixelHeight: 100,
            parameterSets: [Data([1])]
        )
    }

    @Test("a keyframe that beat display attachment is replayed once")
    func keyframeBeforeDisplayAttachmentIsReplayed() {
        var deferred = DeferredVideoKeyframe()
        deferred.record(frame())

        #expect(deferred.take() == .init(frame: frame(), missedLaterFrames: false))
        #expect(deferred.take() == nil)
    }

    @Test("a delta cannot replace the recovery point")
    func deltaCannotReplaceRecoveryPoint() {
        var deferred = DeferredVideoKeyframe()
        deferred.record(frame())
        deferred.record(frame(keyframe: false))

        #expect(deferred.take()?.frame == frame())
    }

    @Test("a delta dropped after the keyframe means the replay needs a fresh keyframe")
    func droppedDeltaIsReported() {
        var deferred = DeferredVideoKeyframe()
        deferred.record(frame())
        deferred.record(frame(keyframe: false))

        #expect(deferred.take()?.missedLaterFrames == true)
    }

    @Test("a newer keyframe clears the dropped deltas before it")
    func newerKeyframeClearsMissedDeltas() {
        var deferred = DeferredVideoKeyframe()
        deferred.record(frame())
        deferred.record(frame(keyframe: false))
        deferred.record(frame())

        #expect(deferred.take()?.missedLaterFrames == false)
    }

    @Test("a delta with no keyframe held is not reported as missed")
    func deltaBeforeAnyKeyframe() {
        var deferred = DeferredVideoKeyframe()
        deferred.record(frame(keyframe: false))
        deferred.record(frame())

        #expect(deferred.take()?.missedLaterFrames == false)
    }

    @Test("the host may reuse the keyframe only for its stream description")
    func hostReuseRequiresMatchingDimensions() {
        var deferred = DeferredVideoKeyframe()
        deferred.record(frame())

        #expect(deferred.latest(matching: config()) == frame())
        #expect(deferred.latest(matching: config(width: 200)) == nil)
    }

    @Test("a changed stream discards the old recovery point")
    func changedStreamDiscardsRecoveryPoint() {
        var deferred = DeferredVideoKeyframe()
        deferred.record(frame())
        deferred.reset()

        #expect(deferred.take() == nil)
    }
}
