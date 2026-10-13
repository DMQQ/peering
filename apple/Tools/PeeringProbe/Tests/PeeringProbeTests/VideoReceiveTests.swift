import Foundation
import Testing
import RemoteCore
@testable import PeeringProbe

/// The `--video-recv` checks, driven with frames directly.
///
/// The transport half of the mode needs a host that is really encoding, but the validation
/// half does not: every failure it reports is a property of the frames themselves. Testing
/// them here is what makes the messages trustworthy on the first run against a live encoder
/// — a check that never fired is indistinguishable from a check that cannot fire.
@Suite("Video receive validation")
struct VideoReceiveTests {
    // MARK: - Builders

    /// A length-prefixed AVCC payload, the shape the host's encoder emits.
    private func avcc(_ nalus: [[UInt8]]) -> Data {
        var out = Data()
        for nalu in nalus {
            let length = UInt32(nalu.count)
            out.append(contentsOf: [
                UInt8(truncatingIfNeeded: length >> 24),
                UInt8(truncatingIfNeeded: length >> 16),
                UInt8(truncatingIfNeeded: length >> 8),
                UInt8(truncatingIfNeeded: length),
            ])
            out.append(contentsOf: nalu)
        }
        return out
    }

    private func configFrame(
        width: Int = 3024,
        height: Int = 1964,
        codec: VideoCodec = .h264,
        sets: [Data] = [Data([0x67, 0x11, 0x22]), Data([0x68, 0x33])]
    ) throws -> Frame {
        Frame(
            kind: .videoConfig,
            payload: try MessageCodec.encode(
                VideoStreamConfig(
                    sourceID: "display:1", codec: codec, pixelWidth: width,
                    pixelHeight: height, parameterSets: sets
                )
            )
        )
    }

    private func videoFrame(
        keyframe: Bool = true,
        width: Int = 3024,
        height: Int = 1964,
        pts: Int64 = 0,
        timescale: Int32 = 600,
        body: Data? = nil
    ) -> Frame {
        let frame = EncodedVideoFrame(
            isKeyframe: keyframe,
            pixelWidth: width,
            pixelHeight: height,
            presentationTime: VideoTimestamp(value: pts, timescale: timescale),
            data: body ?? avcc([[0x65, 0xAA, 0xBB]])
        )
        return Frame(kind: .videoFrame, payload: frame.encoded())
    }

    private func failure(_ receiver: VideoReceiver) -> String {
        receiver.current.failure ?? ""
    }

    // MARK: - AVCC well-formedness

    @Test("a payload whose NALUs tile it exactly counts them")
    func avccTiles() throws {
        let payload = avcc([[0x65, 0x01], [0x41], [0x41, 0x02, 0x03]])
        let count = try Probe.avccNALUCount(payload, lengthSize: 4)
        #expect(count == 3)
    }

    @Test("a trailing fragment fails rather than being ignored")
    func avccTrailingFragment() throws {
        var payload = avcc([[0x65, 0x01]])
        payload.append(contentsOf: [0x00, 0x00])
        #expect(throws: Probe.ProbeError.self) {
            _ = try Probe.avccNALUCount(payload, lengthSize: 4)
        }
    }

    @Test("a zero-length NALU fails")
    func avccZeroLength() throws {
        var payload = avcc([[0x65, 0x01]])
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        #expect(throws: Probe.ProbeError.self) {
            _ = try Probe.avccNALUCount(payload, lengthSize: 4)
        }
    }

    @Test("a NALU longer than the bytes that follow it fails")
    func avccOverrun() throws {
        var payload = Data([0x00, 0x00, 0x00, 0x40])
        payload.append(contentsOf: [0x65, 0x01])
        #expect(throws: Probe.ProbeError.self) {
            _ = try Probe.avccNALUCount(payload, lengthSize: 4)
        }
    }

    @Test("an empty payload fails")
    func avccEmpty() throws {
        #expect(throws: Probe.ProbeError.self) {
            _ = try Probe.avccNALUCount(Data(), lengthSize: 4)
        }
    }

    /// The regression that matters most here: a `Data` slice's indices do not start at zero,
    /// and reading offsets from zero walks into the wrong bytes. This codebase has already
    /// lost time to exactly that mistake once.
    @Test("a slice is walked from its own startIndex, not from zero")
    func avccRespectsStartIndex() throws {
        let payload = avcc([[0x65, 0x01, 0x02], [0x41, 0x03]])
        let padded = Data([0xFF, 0xFF, 0xFF]) + payload
        let slice = padded[3...]

        #expect(slice.startIndex == 3)
        let count = try Probe.avccNALUCount(slice, lengthSize: 4)
        #expect(count == 2)
    }

    // MARK: - Ordering

    @Test("config then keyframe is accepted and counted")
    func happyPath() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())
        try receiver.ingest(videoFrame(pts: 0))
        try receiver.ingest(videoFrame(keyframe: false, pts: 1000))

        let snapshot = receiver.current
        #expect(snapshot.failure == nil)
        #expect(snapshot.frames == 2)
        #expect(snapshot.keyframes == 1)
        #expect(snapshot.config?.pixelWidth == 3024)
        #expect(snapshot.config?.codec == .h264)
        #expect(snapshot.config?.parameterSets.count == 2)
        #expect(snapshot.first?.value == 0)
        #expect(snapshot.last?.value == 1000)
        #expect(snapshot.bytes == 2 * avcc([[0x65, 0xAA, 0xBB]]).count)
    }

    @Test("a frame before any config is named as such")
    func frameBeforeConfig() throws {
        let receiver = VideoReceiver()
        receiver.ingest(videoFrame())
        #expect(failure(receiver).contains("before any videoConfig"))
    }

    @Test("a first frame that is not a keyframe is named as such")
    func firstFrameNotKeyframe() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())
        receiver.ingest(videoFrame(keyframe: false, pts: 0))
        #expect(failure(receiver).contains("not a keyframe"))
    }

    @Test("a delta after a keyframe is fine")
    func deltaAfterKeyframe() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())
        receiver.ingest(videoFrame(pts: 0))
        receiver.ingest(videoFrame(keyframe: false, pts: 100))
        #expect(receiver.current.failure == nil)
        #expect(receiver.current.frames == 2)
    }

    @Test("a config change re-arms the keyframe requirement")
    func configUpdateReArmsKeyframe() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())
        receiver.ingest(videoFrame(pts: 0))

        try receiver.ingest(configFrame(width: 1512, height: 982))
        receiver.ingest(videoFrame(keyframe: false, width: 1512, height: 982, pts: 100))

        #expect(failure(receiver).contains("not a keyframe"))
        #expect(receiver.current.configUpdates == 1)
    }

    // MARK: - Frame contents

    @Test("a frame whose size disagrees with the config is named as such")
    func dimensionMismatch() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())
        receiver.ingest(videoFrame(width: 1920, height: 1080, pts: 0))
        #expect(failure(receiver).contains("1920×1080"))
        #expect(failure(receiver).contains("3024×1964"))
    }

    @Test("presentation timestamps that go backwards are named as such")
    func backwardsTimestamps() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())
        receiver.ingest(videoFrame(pts: 1000))
        receiver.ingest(videoFrame(keyframe: false, pts: 999))
        #expect(failure(receiver).contains("backwards"))
    }

    @Test("equal timestamps are not backwards")
    func equalTimestamps() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())
        receiver.ingest(videoFrame(pts: 1000))
        receiver.ingest(videoFrame(keyframe: false, pts: 1000))
        #expect(receiver.current.failure == nil)
        #expect(receiver.current.frames == 2)
    }

    @Test("a zero timescale is named as such")
    func zeroTimescale() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())
        receiver.ingest(videoFrame(pts: 5, timescale: 0))
        #expect(failure(receiver).contains("zero timescale"))
    }

    @Test("a truncated header is named as such")
    func truncatedHeader() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())
        receiver.ingest(Frame(kind: .videoFrame, payload: Data(repeating: 0, count: 10)))
        #expect(failure(receiver).contains("did not decode as EncodedVideoFrame"))
        #expect(failure(receiver).contains("truncatedHeader"))
    }

    @Test("a declared length that disagrees with the payload is named as such")
    func lengthMismatch() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())

        var payload = videoFrame(pts: 0).payload
        // The header's last four bytes are the declared body length; shortening the body
        // without touching it is exactly the short read this check exists to catch.
        payload.removeLast()
        receiver.ingest(Frame(kind: .videoFrame, payload: payload))

        #expect(failure(receiver).contains("lengthMismatch"))
    }

    @Test("a malformed AVCC payload is named as such")
    func malformedAVCC() throws {
        let receiver = VideoReceiver()
        try receiver.ingest(configFrame())
        // A well-formed header wrapping a body whose length prefix overruns it.
        let body = Data([0x00, 0x00, 0x00, 0x40, 0x65, 0x01])
        let frame = EncodedVideoFrame(
            isKeyframe: true,
            pixelWidth: 3024,
            pixelHeight: 1964,
            presentationTime: VideoTimestamp(value: 0, timescale: 600),
            data: body
        )
        receiver.ingest(Frame(kind: .videoFrame, payload: frame.encoded()))
        #expect(failure(receiver).contains("AVCC"))
    }

    // MARK: - Config sanity

    @Test("a config with no parameter sets is named as such")
    func emptyParameterSets() throws {
        let receiver = VideoReceiver()
        receiver.ingest(try configFrame(sets: []))
        #expect(failure(receiver).contains("parameter set"))
    }

    @Test("a config with zero dimensions is named as such")
    func zeroDimensions() throws {
        let receiver = VideoReceiver()
        receiver.ingest(try configFrame(width: 0, height: 0))
        #expect(failure(receiver).contains("0×0"))
    }

    @Test("a config payload that is not a config is named as such")
    func undecodableConfig() throws {
        let receiver = VideoReceiver()
        receiver.ingest(Frame(kind: .videoConfig, payload: Data("not json".utf8)))
        #expect(failure(receiver).contains("did not decode as VideoStreamConfig"))
    }

    @Test("a message that does not belong on the video channel is named as such")
    func unexpectedKind() throws {
        let receiver = VideoReceiver()
        receiver.ingest(Frame(kind: .catalog, payload: Data()))
        #expect(failure(receiver).contains("catalog"))
    }

    @Test("only the first failure is kept")
    func firstFailureWins() throws {
        let receiver = VideoReceiver()
        receiver.ingest(videoFrame(keyframe: false, pts: 0))
        receiver.ingest(Frame(kind: .catalog, payload: Data()))
        #expect(failure(receiver).contains("before any videoConfig"))
    }
}
