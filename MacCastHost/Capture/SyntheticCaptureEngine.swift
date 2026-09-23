import CoreMedia
import CoreVideo
import Foundation
import os

private let syntheticLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Frames generated in memory, in the exact pixel format a real stream produces.
///
/// Screen Recording permission cannot be assumed: a CI machine, or any process whose responsible
/// application has not been granted it, gets no frames and no error out of ScreenCaptureKit. The
/// buffers are `420v` with real content in them, so everything downstream of the capture engine,
/// pixel format negotiation and rate control included, runs exactly as in production.
///
/// It lives in the host next to the engines that use it rather than in the probe that first
/// needed it, so the probe runs the host's own pixel-format and video-range logic.
enum SyntheticSource {
/// A frame of moving content: a gradient that shifts every frame, with a bright bar travelling
/// across it.
///
/// Both matter. A frame that never changes would let the encoder emit one keyframe and then
/// almost nothing, which would not exercise the delta path; a frame with no structure would
/// compress to nothing and would not exercise rate control.
    static func frame(index: Int, pixelSize: CGSize) -> CVPixelBuffer? {
        let width = max(2, Int(pixelSize.width.rounded(.down)) & ~1)
        let height = max(2, Int(pixelSize.height.rounded(.down)) & ~1)

        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)

// Luma in 16...235: video range, not full range, because that is what `420v` means and a frame
// written outside it is a frame that clips.
        let rows = luma.assumingMemoryBound(to: UInt8.self)
        for y in 0..<lumaHeight {
            let value = UInt8(16 + ((y + index * 3) % 200))
            memset(rows + y * lumaStride, Int32(value), lumaWidth)
        }

        let barWidth = max(2, lumaWidth / 16)
        let barStart = (index * 23) % max(1, lumaWidth - barWidth)
        for y in 0..<lumaHeight {
            memset(rows + y * lumaStride + barStart, 235, barWidth)
        }

// Chroma at 128 is neutral grey. Writing it explicitly matters: an uninitialised chroma plane
// decodes as a random colour cast, and anything comparing this frame against a real one would be
// comparing against noise.
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
            memset(chroma, 128, chromaStride * chromaHeight)
        }

        return buffer
    }

    static func capturedFrame(index: Int, frameRate: Int, pixelSize: CGSize) -> CapturedFrame? {
        guard let buffer = frame(index: index, pixelSize: pixelSize) else { return nil }
        return CapturedFrame(
            pixelBuffer: buffer,
            presentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)),
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            geometry: FrameGeometry(
                contentRect: CGRect(origin: .zero, size: pixelSize),
                contentScale: 1,
                scaleFactor: 1,
                screenRect: nil
            )
        )
    }
}

/// A frame source that makes its own frames, so the pipeline can be driven end to end with no
/// ScreenCaptureKit involvement, no catalogue, and no TCC grant.
///
/// It is not a mock. These are real `420v` IOSurface-backed pixel buffers with moving content in
/// them, handed over on a serial queue the pipeline does not own, through the same ``VideoEncoder``
/// a capture session uses. What is different is only where the pixels came from.
///
/// Three behaviours are deliberately copied from ``CaptureEngine`` because the pipeline's
/// correctness depends on them:
///
/// - Frames arrive on their own serial queue, so the pipeline's locking is exercised rather than
///   bypassed by a callback on the caller's thread.
/// - It never goes idle. An `SCStream` reports idle samples instead of frames when nothing on
///   screen moves, so a keyframe request can sit unanswered; this source always has something new
///   to send, which is what makes an answered keyframe request testable. Which frame carries a
///   keyframe is ``VideoEncoder``'s decision, not this object's.
/// - `stop()` means stopped: the timer is cancelled and a tick already in flight is waited out,
///   so no frame can arrive after the pipeline has released the encoder it was feeding.
final class SyntheticCaptureEngine: CaptureFrameSource, @unchecked Sendable {
    private let lock = NSLock()

/// The queue frames are generated and delivered on, serial for the same reason as the real
/// engine's: VideoToolbox requires presentation timestamps to increase, so two frames must never
/// be submitted concurrently.
    private let queue = DispatchQueue(label: "pl.dmq.peering.capture.synthetic", qos: .userInitiated)

    /// Lets ``stop()`` tell whether it is already running on the queue, where waiting for
    /// that queue would deadlock instead of draining it.
    private static let queueKey = DispatchSpecificKey<UInt8>()

/// What the generator produces. Already even in both dimensions, and kept in the same terms
/// ``VideoEncoder`` builds sessions in, so the pipeline's resize check sees the size it expects.
    let pixelSize: CGSize

    /// Frames per second. Fixed at construction: a stream's rate comes from its
    /// configuration, and this source's comes from here.
    let frameRate: Int

    private var timer: DispatchSourceTimer?
/// Never reset, and never rewound by a stop/start cycle: the encoder requires presentation
/// timestamps that increase, and a fresh session built after a stop must not be handed a
/// timestamp it has already seen.
    private var index = 0
    private var deliveredCount = 0
    private var _onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var _onIdle: (@Sendable (IdleSample) -> Void)?
    private var _onStop: (@Sendable (CaptureError) -> Void)?

    var statistics: CaptureEngine.Statistics {
// `idle` is always zero: nothing here is ever waiting for the screen to change.
        lock.withLock { CaptureEngine.Statistics(delivered: deliveredCount, idle: 0) }
    }

    var onFrame: (@Sendable (CapturedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

/// Never called, since the counter this source is built from moves every tick. It exists because a
/// synthetic pipeline has to be the same shape as a real one from the outside.
    var onIdle: (@Sendable (IdleSample) -> Void)? {
        get { lock.withLock { _onIdle } }
        set { lock.withLock { _onIdle = newValue } }
    }

    /// Nothing here can fail on its own, so this is never called. It exists because a
    /// synthetic pipeline has to be the same shape as a real one from the outside.
    var onStop: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onStop } }
        set { lock.withLock { _onStop = newValue } }
    }

    init(pixelSize: CGSize, frameRate: Int = 60) {
        self.pixelSize = VideoEncoder.encodedSize(for: pixelSize)
        self.frameRate = max(1, frameRate)
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    // MARK: - Lifecycle

    func start(_ request: CaptureStartRequest) async throws {
        guard case .synthetic = request else {
            throw CaptureError.streamFailed("a generated source has no use for a content filter")
        }
        guard lock.withLock({ self.timer == nil }) else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now(),
            repeating: Self.interval(for: frameRate),
// Small, but not zero: the frames are generated in software, and a timer asked for exact wake-ups
// at 60 Hz spends its life being nudged by the scheduler.
            leeway: .milliseconds(1)
        )
        source.setEventHandler { [weak self] in self?.tick() }

        lock.withLock { self.timer = source }
        source.resume()

        syntheticLog.notice("""
            generated capture started · \(Int(self.pixelSize.width), privacy: .public)×\
            \(Int(self.pixelSize.height), privacy: .public) \
            @ \(self.frameRate, privacy: .public) fps
            """)
    }

    func stop() async {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            let current = self.timer
            self.timer = nil
            return current
        }
        guard let timer else { return }

        timer.cancel()
// A tick that had already begun holds the lock only briefly, but may already have read the frame
// it is about to hand out. Waiting for the queue is what makes "no frames after stop" true.
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            queue.sync {}
        }
        syntheticLog.notice("""
            generated capture stopped · \(self.statistics.delivered, privacy: .public) frames \
            delivered in total
            """)
    }

    // MARK: - Frame generation

    private func tick() {
// The index is advanced and the frame is built under the lock, so a tick racing a `stop()` cannot
// decide to deliver after the pipeline has released the encoder.
        let frame = lock.withLock { () -> CapturedFrame? in
            guard timer != nil else { return nil }
            let frame = SyntheticSource.capturedFrame(
                index: index,
                frameRate: frameRate,
                pixelSize: pixelSize
            )
            index += 1
            return frame
        }
        guard let frame else { return }

        lock.withLock { deliveredCount += 1 }
// Outside the lock, and on this queue: whatever the consumer does with a frame must not block the
// next one, and it is the pipeline's lock, not this one, that has to serialise it.
        onFrame?(frame)
    }

    private static func interval(for frameRate: Int) -> DispatchTimeInterval {
        .nanoseconds(Int(1_000_000_000 / Double(max(1, frameRate))))
    }
}
