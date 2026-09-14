import Foundation

/// The video payloads, carried on the dedicated video connection.
///
/// These two messages are handled differently on purpose, because they have opposite
/// shapes:
///
/// - ``VideoStreamConfig`` goes out **once per stream and per source change** (parameter
///   sets are out-of-band in H.264, so they are not repeated on every keyframe). It is
///   small and rare, so it is JSON like the rest of the protocol.
/// - ``EncodedVideoFrame`` goes out up to 60 times a second and carries a whole compressed
///   picture. JSON would base64 the bytes and inflate them by a third on top of an already
///   bandwidth-bound stream, so it gets a fixed binary header instead.
public enum VideoCodec: String, Codable, Sendable, Equatable, CaseIterable {
    case h264
    case hevc
}

/// Everything a decoder needs to make sense of the frames that follow: which codec, what
/// size, and the parameter sets.
///
/// The parameter sets are **not** in the frame data. VideoToolbox emits them in the format
/// description attached to the sample buffer, and in AVCC they stay out of band — which is
/// exactly where `CMVideoFormatDescriptionCreateFromH264ParameterSets` wants them on the
/// client. Re-deriving them from the bitstream would mean parsing NALUs for a value the
/// encoder already handed us.
public struct VideoStreamConfig: Codable, Sendable, Equatable {
    public let codec: VideoCodec
    /// Encoded dimensions in **pixels**, not points. A 1512×982pt Retina display is
    /// 3024×1964 pixels, and the client needs the pixel figure to size its layer.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// SPS and PPS for H.264; VPS, SPS and PPS for HEVC, in that order.
    public let parameterSets: [Data]

    public init(codec: VideoCodec, pixelWidth: Int, pixelHeight: Int, parameterSets: [Data]) {
        self.codec = codec
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.parameterSets = parameterSets
    }

    /// The description an encoded frame implies, or `nil` when that frame does not change it.
    ///
    /// Two rules, and both of them are load-bearing enough to be worth stating rather than
    /// leaving to the caller:
    ///
    /// **A frame with no parameter sets carries no description.** In H.264 they are
    /// out-of-band, so VideoToolbox attaches them to the first frame of a session and
    /// nowhere else. A delta frame therefore says nothing about the stream, and treating its
    /// empty list as a description would erase the parameter sets a client joining
    /// mid-stream depends on — the "connected but the screen is black" failure.
    ///
    /// **A description that has not changed is not re-sent.** Receiving one tells a client
    /// to rebuild its decoder, so re-sending an identical description at frame rate would
    /// leave the client permanently re-initialising and never showing a picture.
    public static func updated(
        from previous: VideoStreamConfig?,
        codec: VideoCodec,
        pixelWidth: Int,
        pixelHeight: Int,
        parameterSets: [Data]
    ) -> VideoStreamConfig? {
        guard !parameterSets.isEmpty else { return nil }
        let candidate = VideoStreamConfig(
            codec: codec,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            parameterSets: parameterSets
        )
        return candidate == previous ? nil : candidate
    }
}

/// A presentation timestamp, in the shape `CMTime` uses.
///
/// Deliberately not `CMTime`: that would pull CoreMedia into a module the iOS and macOS
/// targets share, which is the same mistake that made the original `RemoteCommand` fail to
/// build for iOS. Converting at the boundary costs one line on each side.
public struct VideoTimestamp: Codable, Sendable, Equatable {
    public let value: Int64
    public let timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    public var seconds: Double {
        // A zero timescale is not valid, but this value arrives off the network and a
        // division here would be a crash on a malformed frame.
        timescale == 0 ? 0 : Double(value) / Double(timescale)
    }
}

/// One compressed picture, in AVCC form: a sequence of 4-byte big-endian length-prefixed
/// NALUs with no start codes.
///
/// AVCC rather than Annex-B is not a preference. It is what VideoToolbox emits, and it is
/// what `CMVideoFormatDescriptionCreateFromH264ParameterSets` and
/// `CMSampleBufferCreateReady` expect on the client. Converting to Annex-B and back would
/// be pure overhead on the hot path and would risk the parameter sets being duplicated
/// in-band where the format description already carries them.
public struct EncodedVideoFrame: Sendable, Equatable {
    public let isKeyframe: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let presentationTime: VideoTimestamp
    /// AVCC NALUs, length-prefixed.
    public let data: Data

    public init(
        isKeyframe: Bool,
        pixelWidth: Int,
        pixelHeight: Int,
        presentationTime: VideoTimestamp,
        data: Data
    ) {
        self.isKeyframe = isKeyframe
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.presentationTime = presentationTime
        self.data = data
    }
}

public enum VideoWireError: Error, Equatable, Sendable {
    /// The payload ended before the fixed header did.
    case truncatedHeader(have: Int, need: Int)
    /// The header declared a payload size that does not match what actually arrived.
    ///
    /// Worth failing on rather than trusting the outer frame length: a short read here would
    /// otherwise hand a truncated picture to the decoder, which fails much later and much
    /// less clearly.
    case lengthMismatch(declared: Int, actual: Int)
}

extension EncodedVideoFrame {
    /// flags(1) + width(4) + height(4) + ptsValue(8) + ptsTimescale(4) + dataLength(4)
    public static let headerSize = 25

    private enum Flag {
        static let keyframe: UInt8 = 1 << 0
    }

    /// Big-endian throughout, matching the framing layer's length prefix. A mixed-endian
    /// protocol is a bug waiting for the first ARM-to-x86 pairing.
    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + data.count)
        out.append(isKeyframe ? Flag.keyframe : 0)
        out.appendBigEndian(UInt32(clamping: pixelWidth))
        out.appendBigEndian(UInt32(clamping: pixelHeight))
        out.appendBigEndian(UInt64(bitPattern: presentationTime.value))
        out.appendBigEndian(UInt32(bitPattern: presentationTime.timescale))
        out.appendBigEndian(UInt32(clamping: data.count))
        out.append(data)
        return out
    }

    public init(decoding payload: Data) throws {
        guard payload.count >= Self.headerSize else {
            throw VideoWireError.truncatedHeader(have: payload.count, need: Self.headerSize)
        }

        // `payload` arrives as a slice of the decoder's buffer, so it does not start at
        // index 0. Every offset below is relative to `startIndex`, not to zero.
        let base = payload.startIndex
        let flags = payload[base]
        let width = payload.readBigEndianUInt32(at: base + 1)
        let height = payload.readBigEndianUInt32(at: base + 5)
        let ptsValue = payload.readBigEndianUInt64(at: base + 9)
        let ptsTimescale = payload.readBigEndianUInt32(at: base + 17)
        let declaredLength = payload.readBigEndianUInt32(at: base + 21)

        let body = payload[(base + Self.headerSize)...]
        guard Int(declaredLength) == body.count else {
            throw VideoWireError.lengthMismatch(declared: Int(declaredLength), actual: body.count)
        }

        self.init(
            isKeyframe: flags & Flag.keyframe != 0,
            pixelWidth: Int(width),
            pixelHeight: Int(height),
            presentationTime: VideoTimestamp(
                value: Int64(bitPattern: ptsValue),
                timescale: Int32(bitPattern: ptsTimescale)
            ),
            data: Data(body)
        )
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    func readBigEndianUInt32(at index: Index) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 {
            value = (value << 8) | UInt32(self[index + offset])
        }
        return value
    }

    func readBigEndianUInt64(at index: Index) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 {
            value = (value << 8) | UInt64(self[index + offset])
        }
        return value
    }
}

/// Which frame to keep when only one can be buffered for a channel that has fallen behind.
///
/// Video frames are **droppable** where commands are not: the client cannot use a stale
/// picture, so sending it late is worse than not sending it at all. When the link
/// backpressures, something has to go, and these rules decide what.
///
/// Living here rather than in the host is deliberate — it is pure logic over values, so it
/// can be tested directly. The alternative was a policy buried in a networking class where
/// it could only be observed by running a real display and a real client.
public enum VideoDropPolicy {
    /// - Returns: the frame to hold for sending next.
    public static func superseded(
        _ waiting: EncodedVideoFrame,
        by arriving: EncodedVideoFrame
    ) -> EncodedVideoFrame {
        // A keyframe wins unconditionally. It is the only frame that can start a decoder
        // from nothing, so discarding one in favour of a delta can leave the client showing
        // nothing at all until the next one — the "connected but the screen is black" bug.
        if arriving.isKeyframe { return arriving }

        // The mirror of that rule: an undelivered keyframe is never thrown away for a
        // delta. The delta is worthless without it.
        if waiting.isKeyframe { return waiting }

        // Otherwise the newest picture is the most useful one.
        return arriving
    }
}
