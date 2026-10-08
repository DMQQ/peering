import Foundation
import Testing

@testable import RemoteCore

@Suite("Video over the control channel")
struct VideoChunkTests {
    private func payload(bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    /// Only chunk frames reach the reassembler; a whole frame is not a header.
    private func feed(_ frames: [Frame], into reassembler: inout VideoChunkReassembler) throws -> Frame? {
        var result: Frame?
        for frame in frames where frame.kind != .videoChunk {
            result = frame
        }
        for frame in frames where frame.kind == .videoChunk {
            if let whole = try reassembler.ingest(frame) { result = whole }
        }
        return result
    }

    @Test("a payload that fits a control message travels as itself")
    func smallPayloadIsNotChunked() {
        let frames = VideoChunkEncoder.encode(
            kind: .videoFrame,
            payload: payload(bytes: 900),
            frameID: 1
        )

        #expect(frames.count == 1)
        #expect(frames[0].kind == .videoFrame)
        #expect(frames[0].payload == payload(bytes: 900))
    }

    @Test("a large payload is cut up and comes back byte for byte")
    func largePayloadRoundTrips() throws {
        let original = payload(bytes: 200_000)
        let frames = VideoChunkEncoder.encode(kind: .videoFrame, payload: original, frameID: 7)

        #expect(frames.count == 13)

        var reassembler = VideoChunkReassembler()
        let whole = try feed(frames, into: &reassembler)

        #expect(whole?.kind == .videoFrame)
        #expect(whole?.payload == original)
    }

    @Test("no chunk is anywhere near the control channel's payload cap")
    func chunksFitTheControlCap() {
        let frames = VideoChunkEncoder.encode(
            kind: .videoFrame,
            payload: payload(bytes: 300_000),
            frameID: 2
        )

        for frame in frames {
            #expect(FrameEncoder.encode(frame).count <= ProtocolInfo.maxControlPayload)
        }
    }

    @Test("the pieces may arrive in any order")
    func chunksReassembleOutOfOrder() throws {
        let original = payload(bytes: 70_000)
        var frames = VideoChunkEncoder.encode(kind: .videoFrame, payload: original, frameID: 3)
        frames.reverse()

        var reassembler = VideoChunkReassembler()
        let whole = try feed(frames, into: &reassembler)

        #expect(whole?.payload == original)
    }

    /// A newer frame's piece abandons whatever was being assembled, so a lost chunk cannot wedge the picture.
    @Test("a lost chunk costs one picture and not the next one")
    func lostChunkDoesNotWedgeTheStream() throws {
        var reassembler = VideoChunkReassembler()

        let first = VideoChunkEncoder.encode(kind: .videoFrame, payload: payload(bytes: 80_000), frameID: 10)
        #expect(try feed(Array(first.dropLast()), into: &reassembler) == nil)

        let second = VideoChunkEncoder.encode(kind: .videoFrame, payload: payload(bytes: 1000), frameID: 11)
        let whole = try feed(second, into: &reassembler)

        #expect(whole?.payload == payload(bytes: 1000))
    }

    @Test("a chunk that arrives twice is not appended twice")
    func duplicateChunkIsIgnored() throws {
        let original = payload(bytes: 40_000)
        var frames = VideoChunkEncoder.encode(kind: .videoFrame, payload: original, frameID: 4)
        frames.insert(frames[0], at: 0)

        var reassembler = VideoChunkReassembler()
        let whole = try feed(frames, into: &reassembler)

        #expect(whole?.payload == original)
    }

    @Test("a truncated header is refused rather than guessed at")
    func truncatedHeaderThrows() {
        var reassembler = VideoChunkReassembler()
        let short = Frame(kind: .videoChunk, payload: Data([0x0A, 0, 0]))

        #expect(throws: VideoChunkError.truncatedHeader(have: 3, need: VideoChunk.headerSize)) {
            _ = try reassembler.ingest(short)
        }
    }

    @Test("a chunk of a chunk is refused")
    func nestedChunkThrows() {
        var reassembler = VideoChunkReassembler()
        let nested = Frame(
            kind: .videoChunk,
            payload: Data([MessageKind.videoChunk.rawValue, 0, 0, 0, 1, 0, 0, 0, 1])
        )

        #expect(throws: VideoChunkError.nestedChunk) {
            _ = try reassembler.ingest(nested)
        }
    }

    @Test("a chunk numbered outside its own count is refused")
    func outOfRangeChunkThrows() {
        var reassembler = VideoChunkReassembler()
        // index 3 of a set of 2, which cannot be a real piece of anything.
        let impossible = Frame(
            kind: .videoChunk,
            payload: Data([MessageKind.videoFrame.rawValue, 0, 0, 0, 1, 0, 3, 0, 2])
        )

        #expect(throws: VideoChunkError.chunkOutOfRange(index: 3, count: 2)) {
            _ = try reassembler.ingest(impossible)
        }
    }

    @Test("a chunk larger than the format allows is refused")
    func oversizedChunkThrows() {
        var payload = Data([MessageKind.videoFrame.rawValue, 0, 0, 0, 1, 0, 0, 0, 1])
        payload.append(Data(repeating: 0, count: VideoChunk.maxPayload + 1))

        var reassembler = VideoChunkReassembler()
        #expect(throws: VideoChunkError.oversizedChunk(bytes: VideoChunk.maxPayload + 1)) {
            _ = try reassembler.ingest(Frame(kind: .videoChunk, payload: payload))
        }
    }

    @Test("a frame too large to hold is abandoned, and the next one is not")
    func oversizedFrameIsAbandoned() throws {
        var reassembler = VideoChunkReassembler()
        let enormous = payload(bytes: VideoChunk.maxReassembledPayload + VideoChunk.maxPayload)
        let notWhole = try feed(
            VideoChunkEncoder.encode(kind: .videoFrame, payload: enormous, frameID: 20),
            into: &reassembler
        )
        #expect(notWhole == nil)

        let next = VideoChunkEncoder.encode(kind: .videoFrame, payload: payload(bytes: 200), frameID: 21)
        #expect(try feed(next, into: &reassembler)?.payload == payload(bytes: 200))
    }
}

@Suite("The video transport fallback decision")
struct VideoFallbackPolicyTests {
    private func healthyPicture(at now: TimeInterval) -> TimeInterval { now - 0.1 }

    @Test("a silent session on an answering control channel asks for the fallback")
    func silenceAsksForTheFallback() {
        var policy = VideoFallbackPolicy()
        let decision = policy.advance(
            now: 10,
            lastPictureAt: 10 - VideoFallbackPolicy.silenceBeforeFallback - 0.1,
            lastControlReplyAt: 9.5,
            applies: true
        )

        #expect(decision == .useControlChannel)
        #expect(policy.isFallback)
    }

    @Test("the first seconds of a session are the probe")
    func sessionStartIsTheProbe() {
        var policy = VideoFallbackPolicy()
        let ready = 100.0

        let tooEarly = policy.advance(
            now: ready + VideoFallbackPolicy.silenceBeforeFallback - 0.1,
            lastPictureAt: ready,
            lastControlReplyAt: ready + 0.4,
            applies: true
        )
        #expect(tooEarly == .none)

        let late = policy.advance(
            now: ready + VideoFallbackPolicy.silenceBeforeFallback + 0.1,
            lastPictureAt: ready,
            lastControlReplyAt: ready + 0.4,
            applies: true
        )
        #expect(late == .useControlChannel)
    }

    @Test("a picture arriving is not a problem to solve")
    func arrivingPicturesAskForNothing() {
        var policy = VideoFallbackPolicy()
        let decision = policy.advance(
            now: 20,
            lastPictureAt: healthyPicture(at: 20),
            lastControlReplyAt: 20,
            applies: true
        )

        #expect(decision == .none)
        #expect(!policy.isFallback)
    }

    /// Moving video onto a failing channel would take it off the lane that still works.
    @Test("a control channel that has gone quiet is left alone")
    func unhealthyControlChannelIsNotUsed() {
        var policy = VideoFallbackPolicy()
        let decision = policy.advance(
            now: 30,
            lastPictureAt: 0,
            lastControlReplyAt: 30 - VideoFallbackPolicy.controlHealthWindow - 0.1,
            applies: true
        )

        #expect(decision == .none)
    }

    @Test("a session that has never heard back asks for nothing yet")
    func noReplyYetIsNotHealth() {
        var policy = VideoFallbackPolicy()
        let decision = policy.advance(now: 40, lastPictureAt: 0, lastControlReplyAt: nil, applies: true)

        #expect(decision == .none)
    }

    @Test("a local session is left alone")
    func localSessionsAreLeftAlone() {
        var policy = VideoFallbackPolicy()
        let decision = policy.advance(now: 50, lastPictureAt: 0, lastControlReplyAt: 49.8, applies: false)

        #expect(decision == .none)
        #expect(!policy.isFallback)
    }

    /// A request can be declined by the host, so one that produced no picture is repeated, but not on every watchdog tick.
    @Test("a request that produced no picture is repeated, at an interval")
    func requestsAreRepeatedAtAnInterval() {
        var policy = VideoFallbackPolicy()
        var now = 100.0
        let silence = 0.0

        #expect(policy.advance(now: now, lastPictureAt: silence, lastControlReplyAt: now, applies: true) == .useControlChannel)

        now += 1
        #expect(policy.advance(now: now, lastPictureAt: silence, lastControlReplyAt: now, applies: true) == .none)

        now += VideoFallbackPolicy.requestRepeatInterval
        #expect(policy.advance(now: now, lastPictureAt: silence, lastControlReplyAt: now, applies: true) == .useControlChannel)
    }

    @Test("a fallback that produced a picture is not asked for again")
    func aWorkingFallbackIsLeftAlone() {
        var policy = VideoFallbackPolicy()
        var now = 150.0
        _ = policy.advance(now: now, lastPictureAt: 0, lastControlReplyAt: now, applies: true)

        now += 10
        let picture = now - 0.2
        #expect(policy.advance(now: now, lastPictureAt: picture, lastControlReplyAt: now, applies: true) == .none)
    }

    private func pictureArrived(_ policy: inout VideoFallbackPolicy, at now: TimeInterval) -> TimeInterval {
        policy.notePrimaryPicture()
        return now
    }

    @Test("the preferred transport has to deliver two pictures before it is believed")
    func returningNeedsTwoPictures() {
        var policy = VideoFallbackPolicy()
        var now = 200.0
        #expect(policy.advance(now: now, lastPictureAt: 0, lastControlReplyAt: now, applies: true) == .useControlChannel)

        now += VideoFallbackPolicy.minFallbackHold + 0.1
        var pictureAt = pictureArrived(&policy, at: now)
        #expect(policy.advance(now: now, lastPictureAt: pictureAt, lastControlReplyAt: now, applies: true) == .none)

        now += 0.5
        pictureAt = pictureArrived(&policy, at: now)
        #expect(policy.advance(now: now, lastPictureAt: pictureAt, lastControlReplyAt: now, applies: true) == .usePrimaryTransport)
        #expect(!policy.isFallback)
    }

    @Test("one picture is not enough, and neither is two too early")
    func returningWaitsForTheHold() {
        var policy = VideoFallbackPolicy()
        var now = 300.0
        _ = policy.advance(now: now, lastPictureAt: 0, lastControlReplyAt: now, applies: true)

        now += VideoFallbackPolicy.minFallbackHold - 0.1
        var pictureAt = pictureArrived(&policy, at: now)
        pictureAt = pictureArrived(&policy, at: now)
        #expect(policy.advance(now: now, lastPictureAt: pictureAt, lastControlReplyAt: now, applies: true) == .none)

        now += 0.2
        #expect(policy.advance(now: now, lastPictureAt: pictureAt, lastControlReplyAt: now, applies: true) == .usePrimaryTransport)
    }

    /// Pictures on the preferred transport must not count, or a session that just fell back would return on its first frame.
    @Test("pictures counted before the fallback are not evidence")
    func picturesBeforeTheFallbackDoNotCount() {
        var policy = VideoFallbackPolicy()
        policy.notePrimaryPicture()
        policy.notePrimaryPicture()
        policy.notePrimaryPicture()

        var now = 400.0
        #expect(policy.advance(now: now, lastPictureAt: 0, lastControlReplyAt: now, applies: true) == .useControlChannel)

        now += VideoFallbackPolicy.minFallbackHold + 0.1
        let decision = policy.advance(now: now, lastPictureAt: 0, lastControlReplyAt: now, applies: true)

        #expect(decision != .usePrimaryTransport)
        #expect(policy.isFallback)
    }

    @Test("a new session starts from nothing")
    func resetForgetsTheLastSession() {
        var policy = VideoFallbackPolicy()
        var now = 500.0
        _ = policy.advance(now: now, lastPictureAt: 0, lastControlReplyAt: now, applies: true)
        policy.notePrimaryPicture()
        policy.notePrimaryPicture()
        policy.reset()

        #expect(!policy.isFallback)

        now += VideoFallbackPolicy.minFallbackHold + 1
        #expect(policy.advance(now: now, lastPictureAt: 0, lastControlReplyAt: now, applies: true) == .useControlChannel)
    }
}
