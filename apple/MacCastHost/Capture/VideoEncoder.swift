import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

private let encoderLog = Logger(subsystem: "pl.dmq.peering.host", category: "encoder")

enum VideoCodec: String, CaseIterable, Sendable, Equatable {
    case h264
    case hevc

    var title: String { rawValue.uppercased() }

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    var profileLevel: CFString {
        switch self {
        case .h264:
// Main, not Baseline (no B-frames or CABAC, and nothing needs it). AutoLevel because a hardcoded level failed on a 5K display.
            return kVTProfileLevel_H264_Main_AutoLevel
        case .hevc:
            return kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }

/// Per codec: the H.264 accessor returns nothing for an HEVC format description and vice versa.
    func parameterSets(from formatDescription: CMFormatDescription) -> ParameterSets? {
        switch self {
        case .h264:
            var sets: [Data] = []
            var nalUnitHeaderLength: Int32 = 0
            var index = 0

            while true {
                var pointer: UnsafePointer<UInt8>?
                var size: Int = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &nalUnitHeaderLength
                )
                guard status == noErr, let pointer, size > 0 else { break }
                sets.append(Data(bytes: pointer, count: size))
                index += 1
            }

            guard !sets.isEmpty else { return nil }
            return ParameterSets(sets: sets, nalUnitHeaderLength: Int(nalUnitHeaderLength))
        case .hevc:
            var sets: [Data] = []
            var nalUnitHeaderLength: Int32 = 0
            var index = 0
            while true {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &nalUnitHeaderLength
                )
                guard status == noErr, let pointer, size > 0 else { break }
                sets.append(Data(bytes: pointer, count: size))
                index += 1
            }
            guard !sets.isEmpty else { return nil }
            return ParameterSets(sets: sets, nalUnitHeaderLength: Int(nalUnitHeaderLength))
        }
    }
}

struct ParameterSets: Sendable, Equatable {
    let sets: [Data]
    let nalUnitHeaderLength: Int
}

/// AVCC, not Annex-B: 4-byte big-endian NALU lengths with parameter sets out of band; both ends speak AVCC natively, so start codes would cost a rewrite of every frame.
struct EncodedFrame: Sendable {
    let data: Data
    let presentationTime: CMTime
    let duration: CMTime
    let isKeyframe: Bool
/// Non-empty on keyframes. A new client cannot decode until it has these, so they are carried rather than re-derived.
    let parameterSets: [Data]
    let nalUnitHeaderLength: Int
    let codec: VideoCodec
    let pixelSize: CGSize
    /// The screen rectangle of this exact picture, kept through the asynchronous encoder so input
    /// is not remapped for a newer source or window position while the phone still shows this one.
    let geometry: FrameGeometry
}

/// Lock-guarded class, not an actor: the session is a CoreFoundation handle, frames arrive on a dispatch queue, and an actor would add a hop per frame.
/// The session is created once: rebuilding costs a keyframe and a stall, so nothing tears it down to change an option. Keyframes are asked per frame via requestKeyframe().
final class VideoEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var forceKeyframePending = false
    private var encodedCount = 0
    private var droppedCount = 0
    private var sessionFailed = false
    private var _onFrame: (@Sendable (EncodedFrame) -> Void)?
    private var _onFailure: (@Sendable (CaptureError) -> Void)?

    let codec: VideoCodec
    let pixelSize: CGSize
    let frameRate: Int

    /// Set when VideoToolbox refused a frame or reported an error for one: after sleep or a GPU reset the session stays dead, so the pipeline replaces it instead of feeding it.
    var hasFailed: Bool { lock.withLock { sessionFailed } }

    var onFrame: (@Sendable (EncodedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    var onFailure: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onFailure } }
        set { lock.withLock { _onFailure = newValue } }
    }

    struct Statistics: Sendable, Equatable {
        let encoded: Int
/// Frames dropped because the encoder could not keep up (frameDropped): bitrate or resolution is too much.
        let dropped: Int
        let awaitingKeyframe: Bool
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(encoded: encodedCount, dropped: droppedCount, awaitingKeyframe: forceKeyframePending)
        }
    }

/// - Parameters:
///   - pixelSize: Rounded down to even: 4:2:0 chroma cannot represent odd sizes, and a window dragged odd would fail to encode.
///   - averageBitRate: Bits per second; the default scales with resolution and frame rate.
    init(
        codec: VideoCodec = .h264,
        pixelSize: CGSize,
        frameRate: Int = 60,
        averageBitRate: Int? = nil
    ) throws {
        let size = Self.encodedSize(for: pixelSize)
        let width = Int(size.width)
        let height = Int(size.height)

        self.pixelSize = CGSize(width: width, height: height)
        self.frameRate = frameRate

        let bitRate = averageBitRate ?? Self.defaultBitRate(
            pixelSize: CGSize(width: width, height: height),
            frameRate: frameRate
        )

        func makeSession(_ codec: VideoCodec) -> (VTCompressionSession?, OSStatus) {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: codec.codecType,
// Low-latency rate control is a create-time specification, not a property, and stops VideoToolbox building a lookahead window.
                encoderSpecification: [
                    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                ] as CFDictionary,
                imageBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ] as CFDictionary,
                compressedDataAllocator: nil,
// NULL on purpose: a session with a C callback cannot use the block-based encode call, the only variant whose callback is CM_SWIFT_SENDABLE and so legal under strict concurrency.
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
            return (session, status)
        }

        var (session, status) = makeSession(codec)
        var effectiveCodec = codec

// Hardware HEVC is not universal (some Intel Macs with an older AMD GPU): the only place to fall back to H.264. self.codec is what later frames and the handshake read, so a fallback is never announced as HEVC.
        if status != noErr, codec == .hevc {
            encoderLog.notice("HEVC session creation failed (VideoToolbox error \(status)); falling back to H.264")
            effectiveCodec = .h264
            (session, status) = makeSession(.h264)
        }

        self.codec = effectiveCodec

        guard status == noErr, let session else {
            throw CaptureError.encodingFailed("could not create a session (VideoToolbox error \(status))")
        }
        self.session = session

// Real time: a late frame is worse than a slightly worse one.
// PrioritizeEncodingSpeedOverQuality is not set: the low-latency rate control encoder rejects it (kVTPropertyNotSupportedErr, -12900) and it only logs a fault each launch.
        Self.set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        Self.set(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate))
        Self.set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitRate))
        Self.set(session, kVTCompressionPropertyKey_ProfileLevel, codec.profileLevel)

// Worst case for a client joining mid-stream and cap on how long corruption lasts; new clients use requestKeyframe() instead.
        Self.set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))

// Reordering defaults to true and must be off: it buffers frames, which shows up as permanent latency. A screen share has no B-frames.
        let reordering = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        guard reordering == noErr else {
            VTCompressionSessionInvalidate(session)
            self.session = nil
            throw CaptureError.encodingFailed(
                "the encoder would not disable frame reordering (error \(reordering))"
            )
        }

// Warms the encoder so the first frame does not pay for setup; best effort.
        VTCompressionSessionPrepareToEncodeFrames(session)

        encoderLog.notice("""
            encoder ready · \(codec.codecType, privacy: .public) \
            \(width, privacy: .public)×\(height, privacy: .public) \
            @ \(frameRate, privacy: .public) fps \
            \(bitRate / 1_000_000, privacy: .public) Mbps
            """)
    }

    // MARK: - Encoding

    func encode(_ frame: CapturedFrame) throws {
        guard let session = lock.withLock({ self.session }) else {
            throw CaptureError.encodingFailed("the encoder has already been shut down")
        }

// Per frame, never by rebuilding the session; a request while busy is held for the next frame.
        var properties: CFDictionary?
        if consumeKeyframeRequest() {
// The key is `kVTEncodeFrameOptionKey_ForceKeyFrame`, a frame option passed alongside the frame.
// There is no `kVTCompressionPropertyKey_ForceKeyFrame`.
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        let duration = frame.duration.isValid ? frame.duration : CMTime(value: 1, timescale: CMTimeScale(frameRate))
        // Capture the small value, not `frame`: retaining the whole frame in VideoToolbox's
        // asynchronous callback would also retain the pixel buffer after it has been submitted.
        let geometry = frame.geometry
        var infoFlags = VTEncodeInfoFlags()

// Imported into Swift as `VTCompressionSessionEncodeFrame`, not by its C name
// `VTCompressionSessionEncodeFrameWithOutputHandler`.
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.presentationTime,
            duration: duration,
            frameProperties: properties,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, flags, sampleBuffer in
            self?.finish(
                status: status,
                flags: flags,
                sampleBuffer: sampleBuffer,
                geometry: geometry
            )
        }

        guard status == noErr else {
            lock.withLock { sessionFailed = true }
            throw CaptureError.encodingFailed("the session refused a frame (VideoToolbox error \(status))")
        }

// The block gets its own copy of the flags and finish runs for every frame; counting both would double-count drops.
        if infoFlags.contains(.frameDropped) {
            encoderLog.debug("frame dropped on submit")
        }
    }

/// Safe from any thread. A new client cannot decode until a frame carries parameter sets, so it must not wait for the keyframe interval.
/// The request waits for a frame: a static screen produces none, and on an idle one the only frame is a CursorOverlay/redraw(_:) from pointer movement.
    func requestKeyframe() {
        lock.withLock { forceKeyframePending = true }
    }

/// AverageBitRate can change mid-session on the low-latency controller; it applies from the next keyframe, so also call requestKeyframe().
    func setBitrate(_ bitsPerSecond: Int) {
        guard let session = lock.withLock({ self.session }) else { return }
        Self.set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitsPerSecond))
        encoderLog.notice("bitrate updated to \(bitsPerSecond / 1000, privacy: .public) kbps")
    }

    func shutdown() {
        let session = lock.withLock { () -> VTCompressionSession? in
            let current = self.session
            self.session = nil
            return current
        }
        guard let session else { return }

// Completes in-flight frames so their handlers run; otherwise the last frames are lost.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private func consumeKeyframeRequest() -> Bool {
        lock.withLock {
            defer { forceKeyframePending = false }
            return forceKeyframePending
        }
    }

    // MARK: - Output

    private func finish(
        status: OSStatus,
        flags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        geometry: FrameGeometry
    ) {
// A drop is reported here with a NULL sample buffer: the encoder was handed frames faster than it could encode, so the picture will stutter.
        if flags.contains(.frameDropped) {
            let total = lock.withLock { () -> Int in
                droppedCount += 1
                return droppedCount
            }
            encoderLog.notice("encoder dropped a frame (\(total, privacy: .public) so far)")
            return
        }

        guard status == noErr, let sampleBuffer else {
            let error = CaptureError.encodingFailed("the encoder produced no frame (VideoToolbox error \(status))")
            let failure = lock.withLock { () -> (@Sendable (CaptureError) -> Void)? in
                // A session already shut down is one that was replaced, and its last frames failing is no news.
                guard session != nil else { return nil }
                sessionFailed = true
                return _onFailure
            }
            failure?(error)
            return
        }

        guard let encoded = Self.makeEncodedFrame(
            sampleBuffer,
            codec: codec,
            geometry: geometry
        ) else { return }
        let consumer = lock.withLock { () -> (@Sendable (EncodedFrame) -> Void)? in
            encodedCount += 1
            return _onFrame
        }
// Outside the lock: a consumer must not be able to block the encoder thread.
        consumer?(encoded)
    }

    private static func makeEncodedFrame(
        _ sampleBuffer: CMSampleBuffer,
        codec: VideoCodec,
        geometry: FrameGeometry
    ) -> EncodedFrame? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            return nil
        }

// Parameter sets are in the format description, not the frame data; scanning for start codes finds nothing and leaves the first keyframe undecodable.
        let isKeyframe = isSyncFrame(sampleBuffer)

        var parameterSets: [Data] = []
        var nalUnitHeaderLength = 4
        if isKeyframe, let extracted = codec.parameterSets(from: formatDescription) {
            parameterSets = extracted.sets
            nalUnitHeaderLength = extracted.nalUnitHeaderLength
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)

        return EncodedFrame(
            data: data,
            presentationTime: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration,
            isKeyframe: isKeyframe,
            parameterSets: parameterSets,
            nalUnitHeaderLength: nalUnitHeaderLength,
            codec: codec,
            pixelSize: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)),
            geometry: geometry
        )
    }

/// Read from sample attachments, not CMGetAttachment: that returns nil for every frame (delta frames are marked NotSync on the sample), which reads as every frame being a keyframe and smears a mid-stream joiner.
    private static func isSyncFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        guard let attachments, CFArrayGetCount(attachments) > 0,
              let raw = CFArrayGetValueAtIndex(attachments, 0) else {
// An unmarked sample is a sync sample by definition.
            return true
        }

        let sample = Unmanaged<CFDictionary>.fromOpaque(raw).takeUnretainedValue()
        let markedNotSync = CFDictionaryContainsKey(
            sample,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        )
        return !markedNotSync
    }

    // MARK: - Sizing

/// Shared so size-change checks use the session terms: comparing a real odd width against the rounded one would report a change every frame and rebuild forever.
    static func encodedSize(for pixelSize: CGSize) -> CGSize {
        CGSize(
            width: max(2, Int(pixelSize.width.rounded(.down)) & ~1),
            height: max(2, Int(pixelSize.height.rounded(.down)) & ~1)
        )
    }

    // MARK: - Properties

    @discardableResult
    private static func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) -> Bool {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
// A rejected property is not fatal but a default differing from what the pipeline believes is a latency bug with no other symptom.
            encoderLog.fault("could not set \(String(key), privacy: .public): VideoToolbox error \(status)")
        }
        return status == noErr
    }

/// About 0.12 bits per pixel per frame for screen content, clamped to 4 Mbps (text shimmers below) and 30 Mbps (the encoder stops being the bottleneck above).
    private static func defaultBitRate(pixelSize: CGSize, frameRate: Int) -> Int {
// Scales with frame rate: a budget set too low arrives as a lower frame rate, since the encoder drops frames rather than lowering quality.
        let raw = Double(pixelSize.width * pixelSize.height) * 0.12 * Double(frameRate)
        return Int(min(max(raw, 4_000_000), 30_000_000))
    }
}
