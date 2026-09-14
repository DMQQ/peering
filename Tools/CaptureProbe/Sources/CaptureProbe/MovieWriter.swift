import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Writes the host's `EncodedFrame`s to a playable movie file.
///
/// **The reconstruction is the test.** Nothing here is handed a `CMSampleBuffer` by the
/// encoder — an `EncodedFrame` is only bytes, a timestamp, and (on keyframes) parameter
/// sets, because that is all a client on the far end of a socket will ever have. Turning
/// those back into something a decoder accepts is the same job the client's decoder setup
/// has to do: parameter sets into a format description, an AVCC payload into a block
/// buffer, one timing entry per sample. If the encoder left anything out of what it hands
/// out, the file this produces will not play, and the failure lands here rather than in the
/// client months later.
final class MovieWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    /// Built from the first keyframe's parameter sets and reused for every frame after it.
    /// A decoder needs it on the samples it decodes, and only keyframes carry it.
    private var formatDescription: CMFormatDescription?
    private var startTime: CMTime?
    private var appendedCount = 0
    private var droppedCount = 0
    private var byteCount = 0
    private var keyframeTimes: [CMTime] = []
    private var failure: Error?

    /// Called from VideoToolbox's thread, hence the lock.
    var frameCount: Int { lock.withLock { appendedCount } }
    var keyframeCount: Int { lock.withLock { keyframeTimes.count } }

    /// The size the encoder was asked for, kept to check against what the file turns out to
    /// contain — the track's real dimensions come from the SPS, not from anything here.
    let requestedPixelSize: CGSize

    init(url: URL, pixelSize: CGSize, frameRate: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        requestedPixelSize = pixelSize

        // **`outputSettings: nil`, which is not the obvious choice.** Passing the H.264
        // settings here — codec, width, height — makes the input an *encoder*: it accepts
        // uncompressed buffers and compresses them itself. Handing it the encoder's own
        // compressed output then throws `NSInvalidArgumentException` from inside
        // `appendSampleBuffer:`, at the first frame, with the message "Input buffer must be
        // in an uncompressed format when outputSettings is not nil". A nil settings
        // dictionary makes the input a pass-through: it takes the samples as they are and
        // wraps them in the container, which is what the client's decoder will see too.
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw CaptureProbe.ProbeError(message: "the asset writer refused a video input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw CaptureProbe.ProbeError(
                message: "could not start writing: \(writer.error?.localizedDescription ?? "no reason given")"
            )
        }
    }

    func append(_ frame: EncodedFrame) {
        lock.withLock {
            guard writer.status == .writing else { return }

            if !frame.parameterSets.isEmpty,
               let description = Self.formatDescription(for: frame) {
                formatDescription = description
            }
            guard let formatDescription else {
                // Nothing decodable has arrived yet. A stream always starts with a keyframe
                // for exactly this reason, so this only skips frames if that invariant broke.
                droppedCount += 1
                return
            }

            if startTime == nil {
                // The capture clock is the host's uptime, so timestamps arrive in the
                // millions of seconds. Rebasing to zero keeps the file's timeline sane —
                // and makes it obvious if the encoder ever stops advancing it.
                startTime = frame.presentationTime
                writer.startSession(atSourceTime: .zero)
            }
            guard let startTime else { return }

            let presentationTime = CMTimeSubtract(frame.presentationTime, startTime)
            guard let sampleBuffer = Self.sampleBuffer(
                for: frame,
                formatDescription: formatDescription,
                presentationTime: presentationTime
            ) else {
                droppedCount += 1
                return
            }

            guard input.isReadyForMoreMediaData else {
                droppedCount += 1
                return
            }
            guard input.append(sampleBuffer) else {
                failure = writer.error ?? CaptureProbe.ProbeError(message: "the writer rejected a frame")
                return
            }

            appendedCount += 1
            byteCount += frame.data.count
            if frame.isKeyframe { keyframeTimes.append(presentationTime) }
        }
    }

    struct Summary: Sendable {
        let frames: Int
        let dropped: Int
        let bytes: Int
        /// Presentation times of the keyframes, in seconds from the start of the file —
        /// which is how a forced keyframe is confirmed to have gone out when it was asked
        /// for, rather than at the next scheduled one.
        let keyframeSeconds: [Double]
    }

    func finish() async throws -> Summary {
        let summary = lock.withLock {
            Summary(
                frames: appendedCount,
                dropped: droppedCount,
                bytes: byteCount,
                keyframeSeconds: keyframeTimes.map { $0.seconds }
            )
        }

        guard summary.frames > 0 else {
            writer.cancelWriting()
            throw CaptureProbe.ProbeError(
                message: "no frames were written — the encoder produced nothing to write"
            )
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw CaptureProbe.ProbeError(
                message: "writing failed: \(writer.error?.localizedDescription ?? "no reason given")"
            )
        }
        return summary
    }

    // MARK: - Sample buffer reconstruction

    private static func formatDescription(for frame: EncodedFrame) -> CMFormatDescription? {
        let sets = frame.parameterSets
        guard !sets.isEmpty else { return nil }

        // The parameter set pointers must all stay valid for the duration of the call, so
        // the buffers are nested rather than collected into an array of pointers first.
        func withPointers<R>(_ index: Int, _ pointers: [UnsafePointer<UInt8>], _ sizes: [Int], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
            guard index < sets.count else { return body(pointers, sizes) }
            return sets[index].withUnsafeBytes { raw -> R in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return withPointers(index + 1, pointers, sizes, body)
                }
                return withPointers(index + 1, pointers + [base], sizes + [raw.count], body)
            }
        }

        return withPointers(0, [], []) { pointers, sizes in
            var pointers = pointers
            var sizes = sizes
            var description: CMFormatDescription?
            // This is the same call a client makes on the parameter sets the host sends it,
            // and it parses the dimensions back out of the SPS — which is the only reason
            // the file has a track size at all, since the frame data itself never states it.
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: Int32(frame.nalUnitHeaderLength),
                formatDescriptionOut: &description
            )
            guard status == noErr else { return nil }
            return description
        }
    }

    private static func sampleBuffer(
        for frame: EncodedFrame,
        formatDescription: CMFormatDescription,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        let length = frame.data.count
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let copied = frame.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: frame.duration.isValid ? frame.duration : CMTime(value: 1, timescale: 60),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        // Samples are sync unless marked otherwise. Marking the delta frames is what tells
        // the reader where it may start decoding, and it is also how this check notices a
        // keyframe flag that never made it out of the encoder.
        if !frame.isKeyframe {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_NotSync,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }

        return sampleBuffer
    }
}

/// Reads the file back and decodes it, with the system's own decoder.
///
/// This is playback, not a title check: `AVAssetReader` with pixel-buffer output runs the
/// frames through VideoToolbox exactly as a player would, so a file that decodes here is a
/// file a client can decode.
enum PlaybackCheck {
    struct Report: Sendable {
        let duration: Double
        let pixelSize: CGSize
        let framesDecoded: Int
        /// Mean luma of the last decoded frame, in the 16…235 video range. A black picture
        /// says the container and the codec are fine but nothing was actually captured.
        let lastFrameLuma: Double
    }

    static func run(url: URL) async throws -> Report {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CaptureProbe.ProbeError(message: "the file has no video track")
        }
        let size = try await track.load(.naturalSize)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
        )
        guard reader.canAdd(output) else {
            throw CaptureProbe.ProbeError(message: "could not attach a reader to the video track")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw CaptureProbe.ProbeError(
                message: "could not start decoding: \(reader.error?.localizedDescription ?? "no reason given")"
            )
        }

        var count = 0
        var last: CVPixelBuffer?
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let image = sampleBuffer.imageBuffer {
                count += 1
                last = image
            }
        }

        guard reader.status == .completed else {
            throw CaptureProbe.ProbeError(
                message: "decoding failed after \(count) frames: \(reader.error?.localizedDescription ?? "no reason given")"
            )
        }

        return Report(
            duration: duration.seconds,
            pixelSize: size,
            framesDecoded: count,
            lastFrameLuma: last.map(meanLuma) ?? -1
        )
    }

    private static func meanLuma(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return -1 }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard width > 0, height > 0 else { return -1 }

        var total = 0.0
        let row = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let start = row + y * stride
            for x in 0..<width { total += Double(start[x]) }
        }
        return total / Double(width * height)
    }
}
