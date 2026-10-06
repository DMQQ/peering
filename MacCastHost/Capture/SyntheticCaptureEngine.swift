import CoreMedia
import CoreVideo
import Foundation
import os

private let syntheticLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Without Screen Recording permission (CI) ScreenCaptureKit gives no frames and no error, so this makes 420v frames in memory for the rest of the pipeline.
enum SyntheticSource {
/// Moving content on purpose: a static frame never exercises the delta path, and a flat one never exercises rate control.
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

// Luma in 16...235: video range, as 420v means.
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

// Chroma 128 is neutral grey; an uninitialised plane decodes as a random colour cast.
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

/// Not a mock: real 420v IOSurface buffers through the same VideoEncoder, on a serial queue so the pipeline locking is exercised.
/// Never idle, unlike an SCStream on a still screen, so a keyframe request is always answerable.
/// stop() waits out a tick in flight so no frame arrives after the encoder is released.
final class SyntheticCaptureEngine: CaptureFrameSource, @unchecked Sendable {
    private let lock = NSLock()

/// Serial: VideoToolbox requires increasing presentation timestamps.
    private let queue = DispatchQueue(label: "pl.dmq.peering.capture.synthetic", qos: .userInitiated)

    /// Lets ``stop()`` tell whether it is already running on the queue, where waiting for
    /// that queue would deadlock instead of draining it.
    private static let queueKey = DispatchSpecificKey<UInt8>()

    let pixelSize: CGSize

    let frameRate: Int

    private var timer: DispatchSourceTimer?
/// Never reset: the encoder requires increasing timestamps across stop/start.
    private var index = 0
    private var deliveredCount = 0
    private var _onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var _onIdle: (@Sendable (IdleSample) -> Void)?
    private var _onStop: (@Sendable (CaptureError) -> Void)?

    var statistics: CaptureEngine.Statistics {
        lock.withLock { CaptureEngine.Statistics(delivered: deliveredCount, idle: 0, unreadable: 0) }
    }

    var onFrame: (@Sendable (CapturedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    var onIdle: (@Sendable (IdleSample) -> Void)? {
        get { lock.withLock { _onIdle } }
        set { lock.withLock { _onIdle = newValue } }
    }

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
// Waiting for the queue is what makes no frames after stop true.
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
// Built under the lock so a tick racing stop() cannot deliver after the encoder is released.
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
        onFrame?(frame)
    }

    private static func interval(for frameRate: Int) -> DispatchTimeInterval {
        .nanoseconds(Int(1_000_000_000 / Double(max(1, frameRate))))
    }
}
