import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

private let encoderLog = Logger(subsystem: "pl.dmq.peering.host", category: "encoder")

/// The codec the host encodes with.
///
/// An enum rather than a bare `CMVideoCodecType` so the choice lives in one place: adding
/// HEVC means a case here and a branch in ``parameterSets(from:)``, not a search for every
/// place `kCMVideoCodecType_H264` was written.
enum VideoCodec: Sendable, Equatable {
    case h264

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        }
    }

    var profileLevel: CFString {
        switch self {
        case .h264:
            // Main rather than Baseline: Baseline forbids B-frames and CABAC, and with
            // reordering already off the only thing it would buy is compatibility with
            // hardware nobody is running a Mac client on. `AutoLevel` lets VideoToolbox
            // pick the level from the frame size instead of failing when a 5K display
            // exceeds the level that was hardcoded.
            return kVTProfileLevel_H264_Main_AutoLevel
        }
    }

    /// The SPS/PPS (H.264) or VPS/SPS/PPS (HEVC) carried by a stream's format description.
    ///
    /// These are decoded per codec because the CoreMedia accessor differs, and the
    /// difference is not cosmetic: the H.264 accessor returns nothing for an HEVC format
    /// description and vice versa.
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
        }
    }
}

/// A stream's out-of-band decoder configuration, copied out of the format description.
struct ParameterSets: Sendable, Equatable {
    let sets: [Data]
    /// Width of the length prefix in front of each NALU in the frame data — 4 for AVCC.
    let nalUnitHeaderLength: Int
}

/// One compressed frame, ready to be sent.
///
/// The payload is **AVCC**, not Annex-B: each NALU is preceded by a 4-byte big-endian
/// length, and the parameter sets travel out of band in ``parameterSets``. Annex-B start
/// codes exist for byte-stream formats — files, SDP, a pipe — and would cost a scan and a
/// rewrite of every frame at both ends for nothing, since both ends here are ours and both
/// speak AVCC natively.
struct EncodedFrame: Sendable {
    let data: Data
    let presentationTime: CMTime
    let duration: CMTime
    let isKeyframe: Bool
    /// Non-empty on keyframes, where VideoToolbox emits them. A stream that has just been
    /// built — or a client that has just connected — cannot decode anything until it has
    /// these, which is why they are carried rather than re-derived by the receiver.
    let parameterSets: [Data]
    let nalUnitHeaderLength: Int
    let codec: VideoCodec
    /// Real encoded dimensions, which can differ from the request by a pixel or two.
    let pixelSize: CGSize
}

/// Encodes captured frames to H.264 with `VTCompressionSession`.
///
/// **A lock-guarded class, not an actor**, for the same reason as the capture engine: the
/// session is a CoreFoundation handle with no concurrency checking, frames arrive on a
/// dispatch queue that has no relationship to an actor's executor, and an actor would add a
/// hop to every frame.
///
/// The session is created once and kept. VideoToolbox sessions are expensive to build —
/// they reach into the hardware encoder — and rebuilding one mid-stream costs a keyframe
/// and a visible stall, so nothing here tears a session down to change an option. Keyframes
/// are asked for per frame instead, through ``requestKeyframe()``.
final class VideoEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var forceKeyframePending = false
    private var encodedCount = 0
    private var droppedCount = 0
    private var _onFrame: (@Sendable (EncodedFrame) -> Void)?
    private var _onFailure: (@Sendable (CaptureError) -> Void)?

    let codec: VideoCodec
    /// The dimensions the session was actually created with, rounded to even.
    let pixelSize: CGSize
    let frameRate: Int

    /// Called for every encoded frame, on whichever thread VideoToolbox finishes on.
    var onFrame: (@Sendable (EncodedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// Called when the encoder fails outright. A dropped frame is not a failure and does
    /// not come through here — see ``statistics``.
    var onFailure: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onFailure } }
        set { lock.withLock { _onFailure = newValue } }
    }

    struct Statistics: Sendable, Equatable {
        /// Frames handed to the network.
        let encoded: Int
        /// Frames the encoder discarded because it could not keep up, reported by it as
        /// `VTEncodeInfoFlags.frameDropped`. These are real losses — the client's stream
        /// stutters — and are the number that says the bitrate or the resolution is too
        /// much for this machine.
        let dropped: Int
        /// A keyframe has been asked for and will be applied to the next frame encoded.
        let awaitingKeyframe: Bool
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(encoded: encodedCount, dropped: droppedCount, awaitingKeyframe: forceKeyframePending)
        }
    }

    /// - Parameters:
    ///   - pixelSize: The frame size to encode. Rounded down to even dimensions: H.264 with
    ///     4:2:0 chroma cannot represent an odd width or height, and a window dragged to an
    ///     odd size would otherwise make the session fail to encode at all. The client maps
    ///     input through normalized coordinates, so a one-pixel difference is invisible.
    ///   - averageBitRate: Bits per second. The default scales with resolution and frame
    ///     rate, which is the only way to get one number that is sane for both a 1440p
    ///     laptop panel and a 5K desktop.
    init(
        codec: VideoCodec = .h264,
        pixelSize: CGSize,
        frameRate: Int = 60,
        averageBitRate: Int? = nil
    ) throws {
        let size = Self.encodedSize(for: pixelSize)
        let width = Int(size.width)
        let height = Int(size.height)

        self.codec = codec
        self.pixelSize = CGSize(width: width, height: height)
        self.frameRate = frameRate

        let bitRate = averageBitRate ?? Self.defaultBitRate(
            pixelSize: CGSize(width: width, height: height),
            frameRate: frameRate
        )

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.codecType,
            // The low-latency rate control mode is a *create-time* specification, not a
            // property: it selects a different encoder configuration entirely, and setting
            // it after creation does nothing. It is what keeps VideoToolbox from building
            // up a lookahead window of frames before emitting the first one.
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ] as CFDictionary,
            compressedDataAllocator: nil,
            // NULL, and it has to be: the header states that a session created with a C
            // callback "cannot be called with" the block-based encode call, which is the
            // only variant whose callback is `CM_SWIFT_SENDABLE`. That annotation is what
            // makes the output handler legal to write under strict concurrency at all — a
            // C callback's refcon is not, which is what used to force this code into a
            // global mutable box.
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw CaptureError.encodingFailed("could not create a session (VideoToolbox error \(status))")
        }
        self.session = session

        // Real time, and everything that follows from it. This is a live stream: a frame
        // that is late is worse than a frame that is slightly worse looking, so the encoder
        // is told to prefer speed over quality rather than left to its file-encoding
        // defaults.
        //
        // `PrioritizeEncodingSpeedOverQuality` is deliberately *not* set here, though the
        // usual low-latency set includes it. The session was created with
        // `EnableLowLatencyRateControl`, and that encoder rejects the property outright
        // (`kVTPropertyNotSupportedErr`, -12900) — the rate controller it selects already
        // decides speed against quality, so there is nothing left for the flag to say. Asking
        // anyway costs nothing at runtime and logs a fault on every launch, which is worse
        // than not asking: a fault that always fires is a fault nobody reads.
        Self.set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        Self.set(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate))
        Self.set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitRate))
        Self.set(session, kVTCompressionPropertyKey_ProfileLevel, codec.profileLevel)

        // Two seconds is the worst case for a client that joins mid-stream, and the cap on
        // how long a corrupted stream stays corrupted. It is not the mechanism a new client
        // uses to get a keyframe — that is `requestKeyframe()`.
        Self.set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))

        // **Frame reordering defaults to true and must be turned off.** Left on, the
        // encoder emits frames out of order and buffers them to do it, which shows up as
        // flat, permanent latency that no amount of tuning elsewhere can remove — the
        // client is waiting for a frame the encoder has decided to hold back. There are no
        // B-frames in a screen share; a frame that has not been sent is not a frame.
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

        // Warms the encoder up so the first frame does not pay for the setup. Best effort:
        // VideoToolbox is allowed to refuse, and the only cost of a refusal is a slower
        // first frame.
        VTCompressionSessionPrepareToEncodeFrames(session)

        encoderLog.notice("""
            encoder ready · \(codec.codecType, privacy: .public) \
            \(width, privacy: .public)×\(height, privacy: .public) \
            @ \(frameRate, privacy: .public) fps \
            \(bitRate / 1_000_000, privacy: .public) Mbps
            """)
    }

    // MARK: - Encoding

    /// Submits a frame. Returns as soon as VideoToolbox has taken it, which is usually
    /// before it has been encoded — the compressed frame arrives through ``onFrame``.
    func encode(_ frame: CapturedFrame) throws {
        guard let session = lock.withLock({ self.session }) else {
            throw CaptureError.encodingFailed("the encoder has already been shut down")
        }

        // Per-frame, never by rebuilding the session. A keyframe request that arrives while
        // the encoder is busy is held until the next frame rather than dropped: the caller
        // asking is a client waiting to be able to decode anything at all.
        var properties: CFDictionary?
        if consumeKeyframeRequest() {
            // The key is `kVTEncodeFrameOptionKey_ForceKeyFrame` — a *frame option*, passed
            // alongside the frame. There is no `kVTCompressionPropertyKey_ForceKeyFrame`.
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        let duration = frame.duration.isValid ? frame.duration : CMTime(value: 1, timescale: CMTimeScale(frameRate))
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
            self?.finish(status: status, flags: flags, sampleBuffer: sampleBuffer)
        }

        guard status == noErr else {
            throw CaptureError.encodingFailed("the session refused a frame (VideoToolbox error \(status))")
        }

        // The out-parameter form of the drop flag. The block gets its own copy of the flags,
        // so a drop can be reported through either; counting both would double-count, and
        // `finish` is the one that runs for every frame.
        if infoFlags.contains(.frameDropped) {
            encoderLog.debug("frame dropped on submit")
        }
    }

    /// Asks for the next frame to be a keyframe.
    ///
    /// Safe to call from any thread at any time, including before the first frame. This is
    /// the whole mechanism behind "a client just connected": the client cannot decode a
    /// single frame until one arrives carrying parameter sets, and it must not wait for the
    /// two-second keyframe interval to elapse.
    ///
    /// **One caveat the caller owns.** A keyframe can only be attached to a frame, so the
    /// request waits for one. ScreenCaptureKit produces no *picture* frames while the display
    /// is completely static, and on an idle screen the only frame that arrives is one
    /// ``CursorOverlay/redraw(_:)`` made out of the pointer's own movement — so the request
    /// is held until either the screen or the pointer moves. A host that must paint
    /// immediately regardless can pair it with `SCScreenshotManager`, which captures a
    /// single frame on demand — that is the next phase's decision, not this type's.
    func requestKeyframe() {
        lock.withLock { forceKeyframePending = true }
    }

    /// Changes the encoder's average bitrate on the running session.
    ///
    /// `VTCompressionPropertyKey_AverageBitRate` can be updated mid-session on the
    /// low-latency rate controller. The change takes effect on the next keyframe, so the
    /// caller should also call `requestKeyframe()` to make the switch visible quickly.
    func setBitrate(_ bitsPerSecond: Int) {
        guard let session = lock.withLock({ self.session }) else { return }
        Self.set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitsPerSecond))
        encoderLog.notice("bitrate updated to \(bitsPerSecond / 1000, privacy: .public) kbps")
    }

    /// Flushes and tears the session down. The encoder cannot be used afterwards.
    func shutdown() {
        let session = lock.withLock { () -> VTCompressionSession? in
            let current = self.session
            self.session = nil
            return current
        }
        guard let session else { return }

        // Completes every frame still in flight so their output handlers run before the
        // session goes away; without this the last few frames of a session are simply lost.
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

    private func finish(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        // A drop is not an error, and it is not silent either: VideoToolbox reports it here
        // and the sample buffer is NULL. It means the encoder was handed frames faster than
        // it could encode them, which on this path means the client's picture will stutter.
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
            let failure = lock.withLock { _onFailure }
            failure?(error)
            return
        }

        guard let encoded = Self.makeEncodedFrame(sampleBuffer, codec: codec) else { return }
        let consumer = lock.withLock { () -> (@Sendable (EncodedFrame) -> Void)? in
            encodedCount += 1
            return _onFrame
        }
        // Read out and called outside the lock: whatever the consumer does with a frame must
        // not be able to block the encoder's own thread, and the closure is not ours to trust.
        consumer?(encoded)
    }

    private static func makeEncodedFrame(_ sampleBuffer: CMSampleBuffer, codec: VideoCodec) -> EncodedFrame? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            return nil
        }

        // The parameter sets live in the format description, *not* in the frame data —
        // VideoToolbox strips them and reports them out of band. Scanning the payload for
        // start codes finds nothing, which is the mistake that makes a client unable to
        // decode the first keyframe.
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
            pixelSize: CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        )
    }

    /// Whether a sample buffer holds a sync frame — an IDR, the only kind a decoder can
    /// start from.
    ///
    /// **Read from the *sample* attachments, not with `CMGetAttachment`.** The two are not
    /// the same thing: `CMSampleBuffer`'s header states that a buffer's own attachments are
    /// distinct from the attachments of its samples, and VideoToolbox marks delta frames
    /// with `kCMSampleAttachmentKey_NotSync` on the sample. `CMGetAttachment` reads the
    /// buffer level, so it returns nil for *every* frame — which reads as "every frame is a
    /// keyframe" and is not a harmless mislabel: it tells the client that any frame is a
    /// safe place to start decoding, and a client that joins mid-stream gets a smear of
    /// garbage. Verified against a real stream: with that bug the encoder's output held
    /// exactly two IDRs (`ffprobe -show_frames`) while all 180 frames were reported as sync.
    private static func isSyncFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        guard let attachments, CFArrayGetCount(attachments) > 0,
              let raw = CFArrayGetValueAtIndex(attachments, 0) else {
            // Nothing was marked as a delta frame. An unmarked sample is a sync sample by
            // definition, and the conservative reading would be worse: assuming a frame is
            // not decodable when it is leaves a client waiting for a keyframe that already
            // went past.
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

    /// The dimensions a session would actually be created with for a frame of this size:
    /// rounded down to even, and never smaller than a 2×2 block.
    ///
    /// Shared with the caller so that "has the surface changed size?" is asked in the same
    /// terms the session was built in. Comparing a resized frame's real width against a
    /// session's rounded one would report a change on every single frame of an oddly sized
    /// window, rebuilding the encoder forever.
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
            // A rejected property is not fatal on its own — the encoder will use its default
            // — but it is never invisible, because a default that differs from what the
            // pipeline believes is a latency bug with no other symptom.
            encoderLog.fault("could not set \(String(key), privacy: .public): VideoToolbox error \(status)")
        }
        return status == noErr
    }

    /// A bitrate for a resolution and frame rate, chosen to be defensible rather than
    /// optimal.
    ///
    /// 0.06 bits per pixel per frame is where screen content — flat regions, sharp text,
    /// limited motion — stops looking obviously compressed, and it scales the way the
    /// problem does: a 5K display has four times the pixels of a 1440p one and needs roughly
    /// four times the bits. The clamps matter more than the constant: below 4 Mbps text
    /// shimmers, and above 30 Mbps the encoder stops being the bottleneck on any connection
    /// a client is likely to have.
    private static func defaultBitRate(pixelSize: CGSize, frameRate: Int) -> Int {
        // 0.12 bits per pixel per frame, where this was 0.06.
        //
        // The old constant is a per-frame budget, and it was half of what H.264 needs for a
        // desktop: at 1512×982 and 60 fps it asked for 5.3 Mbps, which is 0.06 bits for every
        // pixel of every frame. The encoder's answer to a budget it cannot meet is to stop
        // encoding — it drops the frames rather than the quality — so a stream configured for
        // 60 arrived at the phone at 10 to 15, and one configured for 120 arrived at 1. The
        // host's own log said so: "encoder dropped a frame", over and over.
        //
        // Worth stating plainly because the arithmetic is not obvious: this scales with the
        // frame rate, so raising the rate does *not* spread the same bits more thinly — it asks
        // for twice the bits for twice the frames. The per-frame budget is the same at both
        // rates, and it was the per-frame budget that was wrong. What made 120 look worse than
        // 60 was only that there were twice as many frames to refuse.
        let raw = Double(pixelSize.width * pixelSize.height) * 0.12 * Double(frameRate)
        return Int(min(max(raw, 4_000_000), 30_000_000))
    }
}
