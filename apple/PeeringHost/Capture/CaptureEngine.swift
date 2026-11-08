import AppKit
import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

private let engineLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A lock-guarded class, not an actor: SCStream types have no Sendable annotations, and SCStreamOutput callbacks arrive on a dispatch queue, so an actor would add an await hop per frame.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, CaptureFrameSource, @unchecked Sendable {
    private let lock = NSLock()

/// The capture queue, the only thread touching the encoder. Serial: VideoToolbox needs increasing presentation timestamps.
    private let queue = DispatchQueue(label: "pl.dmq.peering.capture", qos: .userInitiated)

    private var stream: SCStream?
    private var deliveredCount = 0
    private var idleCount = 0
    private var unreadableCount = 0
    private var _onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var _onIdle: (@Sendable (IdleSample) -> Void)?
    private var _onStop: (@Sendable (CaptureError) -> Void)?
    private var _onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    private var capturesAudio = false
    private let pacer = StreamPacer()

/// No frames and no idle samples is a stream never really started (usually denied Screen Recording, with no error). Idle samples mean a working stream over a still display. An idle sample can become a frame (see ``CursorOverlay/redraw(_:)``), so `idle` can be high alongside healthy frames.
    struct Statistics: Sendable, Equatable {
        let delivered: Int
        let idle: Int
        /// Samples whose frame info could not be read. Not counted as idle, which is the evidence of a healthy quiet stream.
        let unreadable: Int
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(delivered: deliveredCount, idle: idleCount, unreadable: unreadableCount)
        }
    }

    var onFrame: (@Sendable (CapturedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    var onIdle: (@Sendable (IdleSample) -> Void)? {
        get { lock.withLock { _onIdle } }
        set { lock.withLock { _onIdle = newValue } }
    }

/// Called when the stream stops by itself: sleep/wake, a display change, or the user revoking
/// Screen Recording mid-session. Not called for a stop this object initiated.
    var onStop: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onStop } }
        set { lock.withLock { _onStop = newValue } }
    }

    /// Only fires when the engine was started with ``enableAudio()`` before the first ``start(_:)``.
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)? {
        get { lock.withLock { _onAudio } }
        set { lock.withLock { _onAudio = newValue } }
    }

    func enableAudio() {
        lock.withLock { capturesAudio = true }
    }

    // MARK: - Configuration

/// Choices that differ from defaults on purpose: `420v` so frames reach VideoToolbox without conversion; `queueDepth` 3 not 8 (depth is latency, 133 ms at 60 fps); `.nominal` capture resolution; opaque black background (the clear default composites to junk behind non-display filters); no cursor (the phone draws it).
/// Not set: `scalesToFit` (wrong aspect for windows), `colorSpaceName` and `colorMatrix` (green or washed-out cast).
/// `pixelSize` is passed in because at half resolution the stream is not the source's size.
/// `showsCursor` is false except for a mosaic's tiles, which have no single screen rectangle for the app's own overlay. See ``MosaicCompositor``.
    static func configuration(
        for descriptor: CaptureSourceDescriptor,
        pixelSize: CGSize,
        frameRate: Int,
        showsCursor: Bool = false
    ) throws -> SCStreamConfiguration {
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())

// A zero dimension is a failed stream: ScreenCaptureKit rejects it with an error that does not name the source.
        guard width > 0, height > 0 else {
            throw CaptureError.sourceUnavailable("“\(descriptor.title)” has no size to capture.")
        }

        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 3
        configuration.captureResolution = .nominal
        configuration.width = width
        configuration.height = height
        configuration.backgroundColor = CGColor.black
        configuration.showsCursor = showsCursor

// Same number as the encoder's: a mismatch stutters silently instead of failing.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        return configuration
    }

    static func configureAudio(_ configuration: SCStreamConfiguration) {
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
    }

    // MARK: - Lifecycle

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        guard lock.withLock({ self.stream == nil }) else { return }

        let audioEnabled = lock.withLock { capturesAudio }
        if audioEnabled { Self.configureAudio(configuration) }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if audioEnabled {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            }
        } catch {
            throw CaptureError.from(error)
        }

        lock.withLock { self.stream = stream }

        do {
            try await stream.startCapture()
        } catch {
            CaptureHostHooks.reportFailure(error)
            lock.withLock { self.stream = nil }
            throw CaptureError.from(error)
        }

// A stop that arrived mid-start leaves nobody to tear this stream down, and it would capture the whole screen forever. Reachable from the compositor's tile streams.
        let abandoned = lock.withLock { self.stream !== stream }
        if abandoned {
            engineLog.notice("a stream started after the capture was stopped; stopping it")
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
            try? stream.removeStreamOutput(self, type: .audio)
            return
        }

        pacer.attach(stream: stream, configuration: configuration)

        engineLog.notice("""
            capture started · \(configuration.width, privacy: .public)×\
            \(configuration.height, privacy: .public) \
            @ \(frameRateDescription(configuration), privacy: .public)
            """)
    }

/// A stream is the case with something to be handed; reaching the other here is a caller's bug.
    func start(_ request: CaptureStartRequest) async throws {
        switch request {
        case .stream(let filter, let configuration):
            try await start(filter: filter, configuration: configuration)

        case .synthetic:
            throw CaptureError.streamFailed("a stream cannot be started without a filter and a configuration")

        case .mosaic:
// A mosaic is N streams owned by ``MosaicCompositor``; handing it here is a caller's bug.
            throw CaptureError.streamFailed("a mosaic is started by the compositor that owns its streams, not by one stream")
        }
    }

/// Reconfigures a running stream without stopping it: a stop and start costs a second or more of black, on every tile of a mosaic at once.
    func reconfigure(_ configuration: SCStreamConfiguration) async throws {
        let stream = lock.withLock { self.stream }
        guard let stream else { return }
        try await stream.updateConfiguration(configuration)
    }

    /// Makes the stream draw a frame even though nothing on screen changed.
    func refreshFrame() {
        pacer.refresh()
    }

    /// Nil, or a rate at or above the one the stream started at, restores it.
    func limitFrameRate(to framesPerSecond: Int?) {
        pacer.limit(to: framesPerSecond)
    }

    func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            let current = self.stream
            self.stream = nil
            return current
        }
        pacer.detach()
        guard let stream else { return }

        do {
            try await stream.stopCapture()
        } catch {
// Stop can fail when the stream already died (how sleep/wake ends it); nothing to do.
            engineLog.debug("stopCapture reported \(error.localizedDescription, privacy: .public)")
        }
        try? stream.removeStreamOutput(self, type: .screen)
        try? stream.removeStreamOutput(self, type: .audio)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            guard sampleBuffer.isValid else { return }
            lock.withLock { _onAudio }?(sampleBuffer)
            return
        }
        guard type == .screen, sampleBuffer.isValid else { return }

// `.complete` and `.started` carry a picture (dropping `.started` shows nothing on a static screen until something moves); `.idle` is not frame loss.
// `.blank`, `.suspended` and `.stopped` carry no image.
// An idle sample is forwarded so the pointer can be redrawn: with `showsCursor` off, a moving pointer over a still screen changes no pixel the stream watches.
// Forwarded without looking at its image buffer, which the stream reuses once this returns. See ``IdleSample``.
        let info = Self.frameInfo(of: sampleBuffer)
        let status = info?.status

        guard status == .complete || status == .started else {
            // No status at all is unclassifiable and may have been a dropped picture: counted apart from `idle`, which means a quiet stream is a working one.
            guard let status else {
                lock.withLock { unreadableCount += 1 }
                return
            }
            lock.withLock { idleCount += 1 }

            if status == .idle {
                onIdle?(IdleSample(
                    geometry: Self.geometry(from: info),
                    presentationTime: sampleBuffer.presentationTimeStamp,
                    duration: sampleBuffer.duration
                ))
            }
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            lock.withLock { idleCount += 1 }
            return
        }
        lock.withLock { deliveredCount += 1 }

        let duration = sampleBuffer.duration
        let frame = CapturedFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: sampleBuffer.presentationTimeStamp,
            duration: duration.isValid ? duration : .invalid,
            geometry: Self.geometry(from: info)
        )
        onFrame?(frame)
    }

    // MARK: - SCStreamDelegate

/// `-3821` is expected (lid, monitor, resolution change); `-3801` means Screen Recording was never granted or was revoked. Both map in ``CaptureError/from(_:)``.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let mapped = CaptureError.from(error)
        engineLog.error("stream stopped: \(mapped.errorDescription ?? "unknown", privacy: .public)")
        pacer.detach()
        lock.withLock { self.stream = nil }
        onStop?(mapped)
    }

}

private func frameRateDescription(_ configuration: SCStreamConfiguration) -> String {
    let interval = configuration.minimumFrameInterval
    guard interval.isValid, interval.value > 0 else { return "the display's own rate" }
    return "\(Int((Double(interval.timescale) / Double(interval.value)).rounded())) fps"
}
