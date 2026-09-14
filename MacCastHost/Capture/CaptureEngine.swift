import AppKit
import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

private let engineLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// One frame off the stream, still in the `420v` pixel format the stream was configured for.
///
/// `@unchecked Sendable` because it carries a `CVPixelBuffer`, which is a CoreVideo
/// reference type the compiler cannot prove safe to move between threads. It is safe in
/// practice for the one hop that matters here: the buffer is delivered once, handed to
/// VideoToolbox, and never touched again — and VideoToolbox retains it for as long as it
/// needs it, which is why the encoder may return before the frame has been read.
struct CapturedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    /// Invalid when the stream reported none; the encoder substitutes one frame at its
    /// configured rate rather than guessing a duration that would skew the timeline.
    let duration: CMTime
    let geometry: FrameGeometry
}

/// Where the captured content sits inside the surface the stream produces.
///
/// This exists because the surface is not the content for anything but a full display: an
/// application filter composites its windows onto the display-sized surface, and a window
/// filter pads the window out to the size it was when the stream started. The content rect
/// is what the client is actually looking at, and it moves whenever the user drags or
/// resizes the window — with no notification, which is why it has to travel with the frame.
struct FrameGeometry: Sendable, Equatable {
    /// Content size and location, in points, in the stream surface's coordinates.
    let contentRect: CGRect?
    /// How much the content was scaled to fit the surface.
    let contentScale: CGFloat?
    /// The display's pixel-per-point factor.
    let scaleFactor: CGFloat?
    /// Where the content is on screen, in global points — the space `CGEvent` posts into.
    let screenRect: CGRect?
}

/// Wraps `SCStream` and hands out pixel buffers.
///
/// **A lock-guarded `final class`, not an actor.** Two separate reasons, and either one is
/// enough:
///
/// 1. `SCStream`, `SCStreamConfiguration` and `SCContentFilter` come from a module whose
///    Swift overlay is compiled with `-swift-version 5` and has no `Sendable` annotations
///    (the SDK's `ScreenCaptureKit.swiftinterface` contains all of 34 lines and mentions
///    neither `Sendable` nor `nonisolated`). They are not concurrency-checked at all, so
///    wrapping them in an actor would be an `await` around state the compiler still is not
///    checking.
/// 2. `SCStreamOutput` is an Objective-C protocol. Conforming an actor to it means the
///    callbacks arrive on a dispatch queue that knows nothing about the actor's executor,
///    so every frame would have to `await` a hop into the actor before anything could be
///    done with it — added latency on the one path that cannot afford any.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, CaptureFrameSource, @unchecked Sendable {
    private let lock = NSLock()

    /// The queue frames are delivered on, and the only thread that touches the encoder.
    /// Serial, so frames cannot be reordered — VideoToolbox requires presentation timestamps
    /// to increase, and submitting two frames concurrently would break that.
    private let queue = DispatchQueue(label: "pl.dmq.peering.capture", qos: .userInitiated)

    private var stream: SCStream?
    private var deliveredCount = 0
    private var idleCount = 0
    private var _onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var _onStop: (@Sendable (CaptureError) -> Void)?

    /// Counters for the two questions a silent capture failure raises: is the stream alive
    /// at all, and is it alive but with nothing to send?
    ///
    /// The distinction matters because they have different causes. No frames and no idle
    /// samples is a stream that was never really started — usually a denied Screen Recording
    /// permission, which produces no error anywhere. A stream that reports idle samples is
    /// working perfectly and the display simply is not changing.
    struct Statistics: Sendable, Equatable {
        let delivered: Int
        let idle: Int
    }

    var statistics: Statistics {
        lock.withLock { Statistics(delivered: deliveredCount, idle: idleCount) }
    }

    /// Called for every frame that carries an image, on the capture queue.
    var onFrame: (@Sendable (CapturedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// Called when the stream stops by itself — sleep/wake, a display change, or the user
    /// revoking Screen Recording mid-session. Not called for a stop this object initiated.
    var onStop: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onStop } }
        set { lock.withLock { _onStop = newValue } }
    }

    // MARK: - Configuration

    /// The stream configuration for a source.
    ///
    /// Every value here is a decision, including the ones that match the defaults:
    ///
    /// - `pixelFormat` — `420v`, bi-planar video-range YCbCr. It is what the H.264 encoder
    ///   wants, so the frames go to VideoToolbox without a colour conversion. `BGRA` would
    ///   push a full-resolution conversion per frame onto the capture queue, which is the
    ///   most expensive avoidable thing in the pipeline.
    /// - `queueDepth` — 3, not the default 8. The queue is a buffer of frames that have been
    ///   captured but not yet handled, so it is latency: at 60 fps, 8 frames is 133 ms of
    ///   delay before anything reaches the client. Three is late enough to ride out a hiccup
    ///   and short enough to feel live.
    /// - `captureResolution` — `.nominal`, meaning no scaling by the system. Scaling here
    ///   would be a second, unmanaged resample of content whose scale is already decided by
    ///   ``CaptureSourceDescriptor/pixelSize``.
    /// - `backgroundColor` — set to opaque black explicitly. The default is *clear*, and a
    ///   clear backdrop over anything that is not a full display (an application filter, or
    ///   a window smaller than its surface) composites to whatever the surface had in it:
    ///   uninitialised garbage.
    /// - `showsCursor` — visible, which is also the default. Worth stating because it is a
    ///   product decision rather than an inherited one: the client draws a pointer from the
    ///   host's cursor position reports, and without the cursor baked into the frames the
    ///   two can disagree, or the pointer can be missing entirely over video and games.
    ///
    /// Two properties are deliberately left alone. `scalesToFit` is not set: it stretches
    /// content to the configured size, which is how a window capture ends up with the wrong
    /// aspect ratio in a client window of a different shape. And neither `colorSpaceName`
    /// nor `colorMatrix` is set — a stream tagged with a colour space the client does not
    /// expect is a stream that decodes with a green or washed-out cast, and the default
    /// matches what the `420v` format already implies. (Note the property is
    /// `colorSpaceName`; there is no `colorSpace` on `SCStreamConfiguration`.)
    static func configuration(
        for descriptor: CaptureSourceDescriptor,
        frameRate: Int
    ) throws -> SCStreamConfiguration {
        let width = Int(descriptor.pixelSize.width.rounded())
        let height = Int(descriptor.pixelSize.height.rounded())

        // A zero dimension is not a degenerate stream, it is a failed one: ScreenCaptureKit
        // rejects the configuration and the error it raises does not name the source.
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
        configuration.showsCursor = true

        // Caps the capture rate rather than the encode rate. A ProMotion panel or a 5K
        // display reports changes at 120 Hz, which would double both the encode load and
        // the bitrate for motion nobody can see through a remote session.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        return configuration
    }

    // MARK: - Lifecycle

    /// Builds a stream for the filter and starts it. Returns once frames may begin arriving.
    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        guard lock.withLock({ self.stream == nil }) else { return }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            throw CaptureError.from(error)
        }

        lock.withLock { self.stream = stream }

        do {
            try await stream.startCapture()
        } catch {
            lock.withLock { self.stream = nil }
            throw CaptureError.from(error)
        }

        engineLog.notice("""
            capture started · \(configuration.width, privacy: .public)×\
            \(configuration.height, privacy: .public) \
            @ \(frameRateDescription(configuration), privacy: .public)
            """)
    }

    /// The pipeline's way in, which has to be one call for both kinds of source. A stream
    /// is the case that has something to be handed; the other exists for sources that
    /// generate their own frames and reaching it here is a caller's bug, not a state.
    func start(_ request: CaptureStartRequest) async throws {
        switch request {
        case .stream(let filter, let configuration):
            try await start(filter: filter, configuration: configuration)

        case .synthetic:
            throw CaptureError.streamFailed("a stream cannot be started without a filter and a configuration")
        }
    }

    /// Stops the stream and waits for it to be gone, so a new one can be started after.
    func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            let current = self.stream
            self.stream = nil
            return current
        }
        guard let stream else { return }

        do {
            try await stream.stopCapture()
        } catch {
            // Stop can fail when the stream has already died on its own — which is exactly
            // how sleep/wake ends it — and there is nothing left to do about that.
            engineLog.debug("stopCapture reported \(error.localizedDescription, privacy: .public)")
        }
        try? stream.removeStreamOutput(self, type: .screen)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // The status decides whether this sample buffer has a picture in it at all.
        //
        // `.complete` and `.started` do. `.started` is the first frame after the stream
        // came up, and it carries real content — dropping it is how a host that starts
        // capturing a static screen shows the client nothing at all until something moves.
        //
        // `.idle` means the display did not change, which is *not* frame loss: frames are
        // being delivered on schedule and there is simply nothing new in them. `.blank`
        // (display asleep), `.suspended` and `.stopped` carry no image either.
        let info = Self.frameInfo(of: sampleBuffer)
        guard info?.status == .complete || info?.status == .started else {
            lock.withLock { idleCount += 1 }
            return
        }
        lock.withLock { deliveredCount += 1 }

        // The sample buffer's surface is only valid while the buffer is alive, and the
        // encoder retains it for as long as it needs; CoreVideo keeps the IOSurface
        // internally, so the reference can be handed straight on.
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

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

    /// The stream died on its own. This is where sleep/wake and display changes arrive.
    ///
    /// `-3821` (`systemStoppedStream`) is expected in normal use and is not a bug: closing
    /// the lid, plugging in a monitor, or changing the resolution all end the stream. `-3801`
    /// (`userDeclined`) means Screen Recording was never granted, or was revoked while the
    /// app was running. Both are translated in ``CaptureError/from(_:)``.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let mapped = CaptureError.from(error)
        engineLog.error("stream stopped: \(mapped.errorDescription ?? "unknown", privacy: .public)")
        lock.withLock { self.stream = nil }
        onStop?(mapped)
    }

    // MARK: - Sample buffer decoding

    /// Everything ScreenCaptureKit attaches to a frame.
    ///
    /// **Read from the sample attachments array, not from a buffer-level attachment, and
    /// the difference between the two is an entire silent failure mode.** ScreenCaptureKit
    /// records the frame's status, content rect and scale in
    /// `CMSampleBufferGetSampleAttachmentsArray` — one dictionary per sample — and attaches
    /// nothing at the buffer level. A `CMGetAttachment` lookup therefore finds none of it and
    /// answers `nil` for every frame.
    ///
    /// That would be a harmless misread if the status were advisory. It is not: the status is
    /// what decides whether a sample carries a picture, so a reader that always answers `nil`
    /// classifies every frame — keyframes included — as one to throw away. Capture starts,
    /// the stream runs at full rate, `startCapture()` never throws, `SCShareableContent`
    /// answers, and not one frame is ever encoded. The symptom is identical to a denied
    /// Screen Recording permission — "the client connected and the screen is black" — reached
    /// from the opposite direction, with the permission fine and the bug here. Nothing in the
    /// log distinguishes them, which is why this is written out at length rather than left
    /// as a one-liner.
    private struct FrameInfo {
        let status: SCFrameStatus?
        let values: [SCStreamFrameInfo: Any]
    }

    private static func frameInfo(of sampleBuffer: CMSampleBuffer) -> FrameInfo? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]], let first = attachments.first else { return nil }

        return FrameInfo(
            status: (first[.status] as? NSNumber).flatMap { SCFrameStatus(rawValue: $0.intValue) },
            values: first
        )
    }

    /// Where the content sits inside the surface, from the frame's own attachments.
    private static func geometry(from info: FrameInfo?) -> FrameGeometry {
        FrameGeometry(
            contentRect: rect(info?.values[.contentRect]),
            contentScale: (info?.values[.contentScale] as? NSNumber).map { CGFloat($0.doubleValue) },
            scaleFactor: (info?.values[.scaleFactor] as? NSNumber).map { CGFloat($0.doubleValue) },
            screenRect: rect(info?.values[.screenRect])
        )
    }

    /// A rectangle out of a frame-info value.
    ///
    /// Two representations are in circulation and which one arrives depends on the key:
    /// an `NSValue` wrapping a `CGRect`, and a dictionary from
    /// `CGRect.dictionaryRepresentation`. Both are accepted rather than one assumed, because
    /// guessing wrong yields a `nil` rect and a `nil` rect is not an error anywhere — it
    /// quietly degrades input mapping for windows and applications, which is the kind of
    /// fault that shows up as a cursor that drifts rather than as anything that fails.
    private static func rect(_ value: Any?) -> CGRect? {
        if let value = value as? NSValue { return value.rectValue }
        if let value = value as? NSDictionary { return CGRect(dictionaryRepresentation: value as CFDictionary) }
        return nil
    }
}

/// A one-line description of the frame interval for the log.
private func frameRateDescription(_ configuration: SCStreamConfiguration) -> String {
    let interval = configuration.minimumFrameInterval
    guard interval.isValid, interval.value > 0 else { return "the display's own rate" }
    return "\(Int((Double(interval.timescale) / Double(interval.value)).rounded())) fps"
}
