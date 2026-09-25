import Foundation
import Testing
@testable import RemoteCore

@Suite("Video wire format")
struct VideoWireTests {
    private func frame(
        keyframe: Bool = true,
        width: Int = 3024,
        height: Int = 1964,
        pts: Int64 = 1234,
        timescale: Int32 = 600,
        body: [UInt8] = [0, 0, 0, 4, 0x65, 0x11, 0x22, 0x33]
    ) -> EncodedVideoFrame {
        EncodedVideoFrame(
            isKeyframe: keyframe,
            pixelWidth: width,
            pixelHeight: height,
            presentationTime: VideoTimestamp(value: pts, timescale: timescale),
            data: Data(body)
        )
    }

    @Test("a frame survives a round trip")
    func roundTrip() throws {
        let original = frame()
        let decoded = try EncodedVideoFrame(decoding: original.encoded())

        #expect(decoded == original)
        #expect(decoded.isKeyframe)
        #expect(decoded.pixelWidth == 3024)
        #expect(decoded.pixelHeight == 1964)
        #expect(decoded.presentationTime.value == 1234)
        #expect(decoded.presentationTime.timescale == 600)
    }

    @Test("the keyframe flag is a flag, not the whole byte")
    func keyframeFlag() throws {
        // A non-keyframe must not accidentally read as a keyframe, and the other seven bits
        // of the flags byte must stay free for later use without breaking this.
        let delta = try EncodedVideoFrame(decoding: frame(keyframe: false).encoded())
        #expect(!delta.isKeyframe)

        let key = try EncodedVideoFrame(decoding: frame(keyframe: true).encoded())
        #expect(key.isKeyframe)
    }

    @Test("an empty frame body is legal")
    func emptyBody() throws {
        // VideoToolbox can emit a sample with no data when it is reconfiguring. Dropping
        // that on the way out is the pipeline's business, not the codec's — a decoder that
        // throws here would turn a routine event into a protocol error.
        let decoded = try EncodedVideoFrame(decoding: frame(body: []).encoded())
        #expect(decoded.data.isEmpty)
        #expect(decoded.isKeyframe)
    }

    @Test("a non-zero-based slice decodes correctly")
    func sliceOffset() throws {
        // This is the case that catches an off-by-startIndex bug. The frame decoder hands
        // over a slice of a larger read buffer, so `payload[0]` is out of bounds in the
        // general case and every offset has to be relative to `startIndex`.
        let encoded = frame().encoded()
        let padded = Data([0xAA, 0xBB, 0xCC]) + encoded
        let slice = padded.dropFirst(3)

        #expect(slice.startIndex != 0)
        let decoded = try EncodedVideoFrame(decoding: slice)
        #expect(decoded == frame())
    }

    @Test("a truncated header is rejected")
    func truncatedHeader() {
        let short = frame().encoded().prefix(EncodedVideoFrame.headerSize - 1)
        #expect(throws: VideoWireError.truncatedHeader(have: 24, need: 25)) {
            try EncodedVideoFrame(decoding: Data(short))
        }
    }

    @Test("a header claiming more data than arrived is rejected")
    func lengthMismatch() {
        // The declared length disagrees with what is actually present. Trusting it would
        // hand a short buffer to the decoder, which fails later and far less clearly.
        var encoded = frame().encoded()
        encoded.removeLast(2)

        #expect(throws: VideoWireError.lengthMismatch(declared: 8, actual: 6)) {
            try EncodedVideoFrame(decoding: encoded)
        }
    }

    @Test("negative presentation times survive")
    func negativeTimestamp() throws {
        // Not hypothetical: VideoToolbox can hand back a negative PTS on the first frame
        // after a session starts. Round-tripping through a signed type is what preserves it.
        let decoded = try EncodedVideoFrame(decoding: frame(pts: -1).encoded())
        #expect(decoded.presentationTime.value == -1)
    }

    @Test("a zero timescale reports zero rather than dividing by zero")
    func zeroTimescale() {
        // A malformed frame must not be able to crash the client with a division.
        let timestamp = VideoTimestamp(value: 100, timescale: 0)
        #expect(timestamp.seconds == 0)
    }

    @Test("seconds is value over timescale")
    func seconds() {
        #expect(VideoTimestamp(value: 600, timescale: 600).seconds == 1.0)
        #expect(VideoTimestamp(value: 300, timescale: 600).seconds == 0.5)
    }

    @Test("a stream config round-trips through JSON")
    func streamConfig() throws {
        let config = VideoStreamConfig(
            sourceID: "display:1",
            codec: .h264,
            pixelWidth: 3024,
            pixelHeight: 1964,
            parameterSets: [Data([0x67, 0x64, 0x00, 0x1F]), Data([0x68, 0xEB])]
        )
        let decoded = try JSONDecoder().decode(
            VideoStreamConfig.self,
            from: JSONEncoder().encode(config)
        )
        #expect(decoded == config)
        #expect(decoded.parameterSets.count == 2)
    }

    @Test("a version-17 stream config is rejected rather than assigned the requested source")
    func oldStreamConfigHasNoInventedIdentity() {
        let old = Data(#"{"codec":"h264","pixelWidth":3024,"pixelHeight":1964,"parameterSets":["Zw=="]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VideoStreamConfig.self, from: old)
        }
    }

    @Test("the encoded header is exactly the documented size")
    func headerSize() {
        // Pinned because both sides hard-code the offset arithmetic against it. A silent
        // change here would be a protocol break, so it should fail loudly instead.
        #expect(EncodedVideoFrame.headerSize == 25)
        #expect(frame().encoded().count == 25 + frame().data.count)
    }
}

@Suite("Audio wire format")
struct AudioWireTests {
    @Test("a PCM frame survives a round trip")
    func roundTrip() throws {
        let samples = Data([0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0xBF])
        let original = EncodedAudioFrame(
            sampleCount: 1,
            channelCount: 2,
            presentationTime: VideoTimestamp(value: 960, timescale: 48_000),
            samples: samples
        )

        #expect(try EncodedAudioFrame(decoding: original.encoded()) == original)
    }

    @Test("a non-zero-based slice decodes correctly")
    func sliceOffset() throws {
        let original = EncodedAudioFrame(
            sampleCount: 1,
            channelCount: 1,
            presentationTime: VideoTimestamp(value: 0, timescale: 48_000),
            samples: Data([0x00, 0x00, 0x00, 0x00])
        )
        let padded = Data([0xAA, 0xBB]) + original.encoded()

        #expect(try EncodedAudioFrame(decoding: padded.dropFirst(2)) == original)
    }

    @Test("a truncated audio header is rejected")
    func truncatedHeader() {
        #expect(throws: AudioWireError.truncatedHeader(have: 19, need: 20)) {
            try EncodedAudioFrame(decoding: Data(repeating: 0, count: 19))
        }
    }

    @Test("the sample body must match the declared shape")
    func lengthMismatch() {
        var payload = Data()
        payload.append(contentsOf: [0, 0, 0, 2]) // two sample frames
        payload.append(contentsOf: [0, 0, 0, 2]) // stereo
        payload.append(Data(repeating: 0, count: 12)) // timestamp
        payload.append(Data(repeating: 0, count: 12)) // needs 2 * 2 * 4 = 16 bytes

        #expect(throws: AudioWireError.lengthMismatch(declared: 16, actual: 12)) {
            try EncodedAudioFrame(decoding: payload)
        }
    }

    @Test("zero channels are rejected")
    func zeroChannels() {
        var payload = Data()
        payload.append(contentsOf: [0, 0, 0, 1])
        payload.append(contentsOf: [0, 0, 0, 0])
        payload.append(Data(repeating: 0, count: 12))

        #expect(throws: AudioWireError.invalidChannelCount(0)) {
            try EncodedAudioFrame(decoding: payload)
        }
    }
}

@Suite("Video drop policy")
struct VideoDropPolicyTests {
    private func frame(_ keyframe: Bool, _ pts: Int64) -> EncodedVideoFrame {
        EncodedVideoFrame(
            isKeyframe: keyframe,
            pixelWidth: 100,
            pixelHeight: 100,
            presentationTime: VideoTimestamp(value: pts, timescale: 600),
            data: Data([0x00, 0x00, 0x00, 0x01, 0x41])
        )
    }

    @Test("a newer delta replaces an older delta")
    func newestDeltaWins() {
        // The whole point of dropping: the client cannot use a stale picture.
        let kept = VideoDropPolicy.superseded(frame(false, 1), by: frame(false, 2))
        #expect(kept.presentationTime.value == 2)
    }

    @Test("a keyframe always supersedes a delta")
    func keyframeWins() {
        let kept = VideoDropPolicy.superseded(frame(false, 1), by: frame(true, 2))
        #expect(kept.isKeyframe)
        #expect(kept.presentationTime.value == 2)
    }

    @Test("a delta never supersedes a waiting keyframe")
    func keyframeIsNeverDropped() {
        // The failure this prevents is the client showing nothing at all: the delta is
        // undecodable without the keyframe, so dropping it loses the whole stream until the
        // next keyframe rather than one frame.
        let kept = VideoDropPolicy.superseded(frame(true, 1), by: frame(false, 2))
        #expect(kept.isKeyframe)
        #expect(kept.presentationTime.value == 1)
    }

    @Test("a newer keyframe replaces an older keyframe")
    func newestKeyframeWins() {
        let kept = VideoDropPolicy.superseded(frame(true, 1), by: frame(true, 2))
        #expect(kept.isKeyframe)
        #expect(kept.presentationTime.value == 2)
    }
}

/// The rule that decides when a client must be told the stream changed.
///
/// Worth its own suite because both failure directions are silent and look identical on a
/// client: a description that is sent too rarely leaves a joining client with no parameter
/// sets (black screen), and one sent too often leaves it rebuilding its decoder forever
/// (also a black screen).
@Suite("Stream description updates")
struct StreamDescriptionTests {
    private let sps = Data([0x67, 0x42, 0xC0, 0x1E])
    private let pps = Data([0x68, 0xCE, 0x3C, 0x80])
    private let otherSPS = Data([0x67, 0x42, 0xC0, 0x1F])

    private func config(
        sourceID: String = "display:1",
        width: Int = 3024,
        height: Int = 1964,
        sets: [Data]? = nil
    ) -> VideoStreamConfig {
        VideoStreamConfig(
            sourceID: sourceID,
            codec: .h264,
            pixelWidth: width,
            pixelHeight: height,
            parameterSets: sets ?? [sps, pps]
        )
    }

    @Test("a keyframe with no prior description establishes one")
    func firstDescription() throws {
        let produced = VideoStreamConfig.updated(
            from: nil, sourceID: "display:1", codec: .h264, pixelWidth: 3024, pixelHeight: 1964,
            parameterSets: [sps, pps]
        )

        let made = try #require(produced)
        #expect(made.pixelWidth == 3024)
        #expect(made.pixelHeight == 1964)
        #expect(made.parameterSets.count == 2)
        #expect(made.codec == .h264)
    }

    @Test("a frame with no parameter sets establishes nothing")
    func deltaEstablishesNothing() {
        // The state a client connecting to a freshly started stream arrives in: the first
        // frames the encoder emits are not keyframes, so no description exists yet. Inventing
        // one from an empty list would hand the client a config it cannot decode with.
        let produced = VideoStreamConfig.updated(
            from: nil, sourceID: "display:1", codec: .h264, pixelWidth: 3024, pixelHeight: 1964,
            parameterSets: []
        )

        #expect(produced == nil)
    }

    @Test("a delta frame does not erase the description")
    func deltaDoesNotErase() {
        // The regression this pins: parameter sets travel out of band in H.264, so every
        // non-keyframe arrives with an empty list. Reading that as "the stream has no
        // parameter sets" throws away the only copy the client can decode against.
        let previous = config()
        let produced = VideoStreamConfig.updated(
            from: previous, sourceID: "display:1", codec: .h264, pixelWidth: 3024,
            pixelHeight: 1964, parameterSets: []
        )

        #expect(produced == nil)
    }

    @Test("an identical description is not re-sent")
    func identicalIsNotResent() {
        // This runs on every keyframe — twice a second at the default interval. A client that
        // rebuilds its decoder on each one never renders a picture.
        let previous = config()
        let produced = VideoStreamConfig.updated(
            from: previous, sourceID: "display:1", codec: .h264, pixelWidth: 3024, pixelHeight: 1964,
            parameterSets: [sps, pps]
        )

        #expect(produced == nil)
    }

    @Test("a source change produces a new description even when the format is identical")
    func sourceChangeIsAChange() throws {
        let previous = config(sourceID: "mosaic:first")
        let produced = VideoStreamConfig.updated(
            from: previous, sourceID: "window:7", codec: .h264,
            pixelWidth: 3024, pixelHeight: 1964, parameterSets: [sps, pps]
        )

        let made = try #require(produced)
        #expect(made.sourceID == "window:7")
    }

    @Test("a resize produces a new description")
    func resizeIsAChange() throws {
        // A captured window being dragged larger changes the surface, which forces the
        // pipeline to rebuild the encoder. The client has to hear about it.
        let previous = config()
        let produced = VideoStreamConfig.updated(
            from: previous, sourceID: "display:1", codec: .h264, pixelWidth: 1920, pixelHeight: 1080,
            parameterSets: [sps, pps]
        )

        let made = try #require(produced)
        #expect(made.pixelWidth == 1920)
        #expect(made.pixelHeight == 1080)
    }

    @Test("new parameter sets at the same size produce a new description")
    func parameterSetChangeIsAChange() throws {
        // Same geometry, different encoder session — which is what a source switch looks
        // like when both sources happen to be the same size. Comparing only the dimensions
        // would leave the client decoding the new stream against the old parameter sets.
        let previous = config()
        let produced = VideoStreamConfig.updated(
            from: previous, sourceID: "display:1", codec: .h264, pixelWidth: 3024, pixelHeight: 1964,
            parameterSets: [otherSPS, pps]
        )

        let made = try #require(produced)
        #expect(made.parameterSets.first == otherSPS)
    }

    @Test("a codec change produces a new description")
    func codecChangeIsAChange() throws {
        let previous = config()
        let produced = VideoStreamConfig.updated(
            from: previous, sourceID: "display:1", codec: .hevc, pixelWidth: 3024, pixelHeight: 1964,
            parameterSets: [sps, pps]
        )

        let made = try #require(produced)
        #expect(made.codec == .hevc)
    }
}
