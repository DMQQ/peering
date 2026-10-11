import Foundation

public enum VideoCodec: String, Codable, Sendable, Equatable, CaseIterable {
    case h264
    case hevc
}

/// The parameter sets are not in the frame data: VideoToolbox emits them in the format description
/// attached to the sample buffer, and in AVCC they stay out of band, which is where
/// `CMVideoFormatDescriptionCreateFromH264ParameterSets` wants them on the client.
public struct VideoStreamConfig: Codable, Sendable, Equatable {
    /// Not implied by the encoded format: two windows, or a window and a
    /// mosaic, can have byte-identical parameter sets and dimensions.
    public let sourceID: String
    public let codec: VideoCodec
    /// Encoded dimensions in pixels, not points: a 1512×982pt Retina display is 3024×1964 pixels,
    /// and the client needs the pixel figure to size its layer.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// SPS and PPS for H.264; VPS, SPS and PPS for HEVC, in that order.
    public let parameterSets: [Data]

    public init(
        sourceID: String,
        codec: VideoCodec,
        pixelWidth: Int,
        pixelHeight: Int,
        parameterSets: [Data]
    ) {
        self.sourceID = sourceID
        self.codec = codec
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.parameterSets = parameterSets
    }

    /// A frame with no parameter sets carries no description: they are out-of-band in H.264,
    /// attached to the first frame of a session and nowhere else, and treating a delta frame's
    /// empty list as a description would erase the parameter sets a client joining mid-stream
    /// depends on.
    /// A description that has not changed is not re-sent: receiving one tells a client to rebuild
    /// its decoder, which at frame rate would leave it permanently re-initialising.
    public static func updated(
        from previous: VideoStreamConfig?,
        sourceID: String,
        codec: VideoCodec,
        pixelWidth: Int,
        pixelHeight: Int,
        parameterSets: [Data]
    ) -> VideoStreamConfig? {
        guard !parameterSets.isEmpty else { return nil }
        let candidate = VideoStreamConfig(
            sourceID: sourceID,
            codec: codec,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            parameterSets: parameterSets
        )
        return candidate == previous ? nil : candidate
    }
}

/// Not `CMTime`, which would pull CoreMedia into a module the iOS and macOS targets share; converting
/// at the boundary costs one line on each side.
public struct VideoTimestamp: Codable, Sendable, Equatable {
    public let value: Int64
    public let timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    public var seconds: Double {
        // A zero timescale is not valid, but this arrives off the network and a division here
        // would be a crash on a malformed frame.
        timescale == 0 ? 0 : Double(value) / Double(timescale)
    }
}

/// AVCC rather than Annex-B because that is what VideoToolbox emits and what
/// `CMVideoFormatDescriptionCreateFromH264ParameterSets` and `CMSampleBufferCreateReady` expect on
/// the client.
public struct EncodedVideoFrame: Sendable, Equatable {
    public let isKeyframe: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let presentationTime: VideoTimestamp
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
    case truncatedHeader(have: Int, need: Int)
    /// Worth failing on rather than trusting the outer frame length: a short read here hands a
    /// truncated picture to the decoder, which fails much later and less clearly.
    case lengthMismatch(declared: Int, actual: Int)
}

extension EncodedVideoFrame {
    /// flags(1) + width(4) + height(4) + ptsValue(8) + ptsTimescale(4) + dataLength(4)
    public static let headerSize = 25

    private enum Flag {
        static let keyframe: UInt8 = 1 << 0
    }

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

        // `payload` is a slice of the decoder's buffer, so every offset below is relative to
        // `startIndex`, not to zero.
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

// MARK: - Audio wire types

public enum AudioCodec: String, Codable, Sendable, Equatable {
    /// Raw 32-bit float PCM, interleaved channels. No compression: the payload is tiny at
    /// audio-typical frame sizes and it avoids a codec negotiation failure.
    case pcmFloat32
}

public struct AudioStreamConfig: Codable, Sendable, Equatable {
    public let codec: AudioCodec
    public let sampleRate: Double
    public let channelCount: Int

    public init(codec: AudioCodec, sampleRate: Double, channelCount: Int) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public enum AudioWireError: Error, Equatable, Sendable {
    case truncatedHeader(have: Int, need: Int)
    case invalidSampleCount(Int)
    case invalidChannelCount(Int)
    case lengthMismatch(declared: Int, actual: Int)
}

public struct EncodedAudioFrame: Sendable, Equatable {
    public let sampleCount: Int
    public let channelCount: Int
    public let presentationTime: VideoTimestamp
    /// Interleaved Float32 samples, in sample-frame order (L0 R0 L1 R1 …).
    public let samples: Data

    public init(
        sampleCount: Int,
        channelCount: Int,
        presentationTime: VideoTimestamp,
        samples: Data
    ) {
        self.sampleCount = sampleCount
        self.channelCount = channelCount
        self.presentationTime = presentationTime
        self.samples = samples
    }

    /// sampleCount(4) + channelCount(4) + ptsValue(8) + ptsTimescale(4)
    public static let headerSize = 20

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + samples.count)
        out.appendBigEndian(UInt32(clamping: sampleCount))
        out.appendBigEndian(UInt32(clamping: channelCount))
        out.appendBigEndian(UInt64(bitPattern: presentationTime.value))
        out.appendBigEndian(UInt32(bitPattern: presentationTime.timescale))
        out.append(samples)
        return out
    }

    public init(decoding payload: Data) throws {
        guard payload.count >= Self.headerSize else {
            throw AudioWireError.truncatedHeader(have: payload.count, need: Self.headerSize)
        }
        let base = payload.startIndex
        let sampleCount = Int(payload.readBigEndianUInt32(at: base))
        let channelCount = Int(payload.readBigEndianUInt32(at: base + 4))
        let ptsValue = payload.readBigEndianUInt64(at: base + 8)
        let ptsTimescale = payload.readBigEndianUInt32(at: base + 16)
        let body = Data(payload[(base + Self.headerSize)...])

        guard sampleCount > 0 else {
            throw AudioWireError.invalidSampleCount(sampleCount)
        }
        // Core Audio channel counts are small, and this bound keeps a malformed frame from
        // driving an unbounded channel loop in the renderer.
        guard (1...32).contains(channelCount) else {
            throw AudioWireError.invalidChannelCount(channelCount)
        }
        let (sampleValues, sampleOverflow) = sampleCount.multipliedReportingOverflow(by: channelCount)
        let (declaredByteCount, byteOverflow) = sampleValues.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !sampleOverflow, !byteOverflow, declaredByteCount == body.count else {
            throw AudioWireError.lengthMismatch(
                declared: sampleOverflow || byteOverflow ? .max : declaredByteCount,
                actual: body.count
            )
        }

        self.init(
            sampleCount: sampleCount,
            channelCount: channelCount,
            presentationTime: VideoTimestamp(
                value: Int64(bitPattern: ptsValue),
                timescale: Int32(bitPattern: ptsTimescale)
            ),
            samples: body
        )
    }
}

/// Video frames are droppable where commands are not: the client cannot use a stale picture, so
/// sending it late is worse than not sending it at all. The rules live here rather than in the host
/// because they are pure logic over values, so they can be tested directly.
public enum VideoDropPolicy {
    public static func superseded(
        _ waiting: EncodedVideoFrame,
        by arriving: EncodedVideoFrame
    ) -> EncodedVideoFrame {
        // A keyframe wins unconditionally: it is the only frame that can start a decoder from
        // nothing, so discarding one in favour of a delta leaves the client showing nothing.
        if arriving.isKeyframe { return arriving }

        // The mirror of that rule: an undelivered keyframe is never thrown away for a delta,
        // which is worthless without it.
        if waiting.isKeyframe { return waiting }

        return arriving
    }
}
