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
/// This is a frame and not a sample. An idle sample that happens to carry an image buffer is an
/// ``IdleSample`` and travels by its own route, because a receipt that sometimes arrives is worse
/// to build on than one that never does.
///
/// `@unchecked Sendable` because it carries a `CVPixelBuffer`, which is a CoreVideo reference type
/// the compiler cannot prove safe to move between threads. It is safe for the one hop that matters:
/// the buffer is delivered once, handed to VideoToolbox, and never touched again, and VideoToolbox
/// retains it for as long as it needs, which is why the encoder may return before the frame has
/// been read.
///
/// That is why ``CursorOverlay/redraw(_:)`` keeps a buffer of its own: the buffer belongs to a pool
/// ScreenCaptureKit reuses, and VideoToolbox is still reading it.
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
/// The surface is not the content for anything but a full display: an application filter composites
/// its windows onto the display-sized surface, and a window filter pads the window out to the size
/// it was when the stream started. The content rect is what the client is actually looking at, and
/// it moves whenever the user drags or resizes the window, with no notification, which is why it
/// travels with the frame.
struct FrameGeometry: Sendable, Equatable {
    /// Content size and location, in points, in the stream surface's coordinates.
    let contentRect: CGRect?
    /// How much the content was scaled to fit the surface.
    let contentScale: CGFloat?
    /// The display's pixel-per-point factor.
    let scaleFactor: CGFloat?
    /// Where the content is on screen, in global points, the space `CGEvent` posts into.
    let screenRect: CGRect?
}

extension FrameGeometry {
/// The input transform this frame implies, or `nil` when the frame does not describe one.
///
/// Built from `screenRect` rather than `contentRect`: `InputTransform` wants a top-left in the
/// global point space `CGEvent` posts into, and `contentRect` is in the stream surface's own
/// coordinates, offset by wherever the surface sits.
///
/// `screenRect` is points and `InputTransform.pixelSize` is pixels, so the same `scaleFactor` that
/// converts one to the other is also the `pointPixelScale`, exactly as ``DisplayGeometry`` builds
/// it for a display. Neither value moves when the stream is configured at half resolution: the
/// factor belongs to the display, not to the surface carrying it. Even if a later macOS answered
/// with the surface's factor instead, `pixelSize` and `pointPixelScale` are both built from it and
/// both directions of the mapping collapse to the same function of `screenRect`.
    var inputTransform: InputTransform? {
        guard let screenRect, screenRect.width > 0, screenRect.height > 0,
              let scaleFactor, scaleFactor > 0
        else { return nil }

        return InputTransform(
            origin: screenRect.origin,
            pixelSize: CGSize(
                width: screenRect.width * scaleFactor,
                height: screenRect.height * scaleFactor
            ),
            pointPixelScale: scaleFactor
        )
    }
}

/// How much of a source's own size the stream is configured to carry.
///
/// Not to be confused with `SCStreamConfiguration.captureResolution`, which is ScreenCaptureKit's
/// choice of what the system composites at and stays `.nominal` either way. This is the size of the
/// surface that comes out.
///
/// A setting rather than a constant because the size of the picture moves every cost in the
/// pipeline at once, and the machine on the other end of that link is a phone.
enum CaptureResolution: String, CaseIterable, Sendable {
/// The size the source reports, and the default.
    case full

    /// Three-quarters the width and height, so about 56% of the pixels.
    case threeQuarters

    /// Half the width and half the height, so a quarter of the pixels.
    case half

/// The size a stream is built at for a source whose own size is `native`.
///
/// Half of the size the stream would otherwise be built at, rather than half of the panel's
/// hardware pixels, and on this Mac those are not the same number: a display's `pixelSize` comes
/// from `CGDisplayPixelsWide`, which answers with the display mode's width, which is points,
/// reporting 1512×982 for a panel whose real pixels are 3024×1964. Halving whatever the stream
/// would have been configured with is the one rule that holds for all three kinds of source.
///
/// Odd dimensions are left odd rather than rounded here: the stream rounds to the nearest point and
/// ``VideoEncoder`` rounds down to even, and both of those have to happen in that order for the
/// encoder's size to match the surface's. See ``CapturePipeline/encode(_:)``.
    func pixelSize(for native: CGSize) -> CGSize {
        switch self {
        case .full: return native
        case .threeQuarters: return CGSize(width: native.width * 0.75, height: native.height * 0.75)
        case .half: return CGSize(width: native.width / 2, height: native.height / 2)
        }
    }
}

/// What the stream is asked to deliver per second.
///
/// Two values rather than a number, because the rate is not a free parameter: it is set on the
/// stream as a minimum frame interval and on the encoder as its timeline, and the two have to be
/// the same number or the encoder codes frames against a clock it was not told about. An enum is
/// what makes them the same number.
///
/// `oneTwenty` only ever gets frames from a display that refreshes faster than 60 times a second:
/// the interval is a ceiling, not a promise.
enum CaptureFrameRate: Int, CaseIterable, Sendable {
    case thirty = 30
    case sixty = 60
    case oneTwenty = 120
}

/// Wraps `SCStream` and hands out pixel buffers.
///
/// A lock-guarded `final class`, not an actor, for two separate reasons and either one is enough:
///
/// 1. `SCStream`, `SCStreamConfiguration` and `SCContentFilter` come from a module whose Swift
///    overlay is compiled with `-swift-version 5` and has no `Sendable` annotations. They are not
///    concurrency-checked at all, so wrapping them in an actor would be an `await` around state
///    the compiler still is not checking.
/// 2. `SCStreamOutput` is an Objective-C protocol. Conforming an actor to it means the callbacks
///    arrive on a dispatch queue that knows nothing about the actor's executor, so every frame
///    would have to `await` a hop into the actor: added latency on the one path that cannot afford
///    any.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, CaptureFrameSource, @unchecked Sendable {
    private let lock = NSLock()

/// The queue frames are delivered on, and the only thread that touches the encoder. Serial, so
/// frames cannot be reordered: VideoToolbox requires presentation timestamps to increase.
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

/// Counters for the two questions a silent capture failure raises: is the stream alive at all, and
/// is it alive but with nothing to send?
///
/// No frames and no idle samples is a stream that was never really started, usually a denied Screen
/// Recording permission, which produces no error anywhere. A stream that reports idle samples is
/// working perfectly and the display simply is not changing.
///
/// What the pair describes is the stream, not the client's screen. An idle sample can become a
/// frame of its own (see ``CursorOverlay/redraw(_:)``), so a pointer moving over a still screen
/// reports a large `idle` and a healthy stream of frames at the same time. The count of frames that
/// reached the client is ``CapturePipeline/Statistics/framesEncoded``, a different question.
    struct Statistics: Sendable, Equatable {
        let delivered: Int
        let idle: Int
        /// Samples whose own frame info could not be read at all, so this side cannot tell a still
        /// picture from a missing one.
        ///
        /// Apart from ``idle``, which is the evidence that a stream is alive with nothing to send:
        /// counting these as idle would let a stream that is dropping every frame report itself as
        /// healthy and quiet.
        let unreadable: Int
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(delivered: deliveredCount, idle: idleCount, unreadable: unreadableCount)
        }
    }

    /// Called for every frame that carries an image, on the capture queue.
    var onFrame: (@Sendable (CapturedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// Called for every sample that carries no new picture, on the capture queue.
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

    /// Called for every audio sample buffer, on the capture queue.
    /// Only fires when the engine was started with ``enableAudio()`` before the first
    /// ``start(_:)``.
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)? {
        get { lock.withLock { _onAudio } }
        set { lock.withLock { _onAudio = newValue } }
    }

    /// Enables audio capture for the next stream start.
    func enableAudio() {
        lock.withLock { capturesAudio = true }
    }

    // MARK: - Configuration

/// The stream configuration for a source.
///
/// Every value here is a decision, including the ones that match the defaults:
///
/// - `pixelFormat`: `420v`, bi-planar video-range YCbCr, which is what the H.264 encoder wants, so
///   frames reach VideoToolbox without a colour conversion. `BGRA` would push a full-resolution
///   conversion per frame onto the capture queue.
/// - `queueDepth`: 3 rather than the default 8. The queue is a buffer of frames captured but not
///   yet handled, so it is latency: at 60 fps, 8 frames is 133 ms of delay.
/// - `captureResolution`: `.nominal`, meaning no scaling by the system. Scaling here would be a
///   second, unmanaged resample of content whose scale the configuration's size already decides.
/// - `backgroundColor`: opaque black explicitly. The default is clear, and a clear backdrop over
///   anything that is not a full display composites to whatever the surface had in it.
/// - `showsCursor`: off. The iPhone renders the commanded pointer immediately, which removes one
///   video round trip and avoids a second cursor baked into the picture.
///
/// Two properties are deliberately left alone. `scalesToFit` is not set: it stretches content to
/// the configured size, which is how a window capture ends up with the wrong aspect ratio. Neither
/// is `colorSpaceName` nor `colorMatrix`: a stream tagged with a colour space the client does not
/// expect decodes with a green or washed-out cast, and the default matches what `420v` implies.
///
/// - Parameter pixelSize: The size of the surface to ask for, which is the source's own or half of
///   it. Passed in rather than read off the descriptor because at half resolution the stream is
///   deliberately not the size the source is.
/// - Parameter showsCursor: Whether ScreenCaptureKit draws the pointer into this stream. `false`
///   everywhere except a mosaic's tiles, where the overlay this app draws itself has no single
///   screen rectangle to place one in. See ``MosaicCompositor``.
    static func configuration(
        for descriptor: CaptureSourceDescriptor,
        pixelSize: CGSize,
        frameRate: Int,
        showsCursor: Bool = false
    ) throws -> SCStreamConfiguration {
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())

// A zero dimension is not a degenerate stream, it is a failed one: ScreenCaptureKit rejects the
// configuration and the error it raises does not name the source.
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

// The stream's half of ``CaptureFrameRate``, and the encoder is built with the same number: a
// stream whose interval says 120 while its encoder was told 60 is a timeline that stutters rather
// than one that fails, which is a bug with no error attached to it.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        return configuration
    }

    /// Enables audio in an already-built configuration. Called after ``configuration(for:pixelSize:frameRate:)``
    /// when the engine is set to capture audio.
    static func configureAudio(_ configuration: SCStreamConfiguration) {
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
    }

    // MARK: - Lifecycle

    /// Builds a stream for the filter and starts it. Returns once frames may begin arriving.
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
            lock.withLock { self.stream = nil }
            throw CaptureError.from(error)
        }

// A stop that arrived while this was starting: the stream is no longer the one this engine holds,
// so nobody is going to tear it down, and left running it captures the whole screen for the life of
// the process. Reachable from the compositor, which starts its tile streams together and can be
// stopped in the middle of doing it.
        let abandoned = lock.withLock { self.stream !== stream }
        if abandoned {
            engineLog.notice("a stream started after the capture was stopped; stopping it")
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
            try? stream.removeStreamOutput(self, type: .audio)
            return
        }

        engineLog.notice("""
            capture started · \(configuration.width, privacy: .public)×\
            \(configuration.height, privacy: .public) \
            @ \(frameRateDescription(configuration), privacy: .public)
            """)
    }

/// The pipeline's way in, which has to be one call for both kinds of source. A stream is the case
/// that has something to be handed; the other exists for sources that generate their own frames,
/// and reaching it here is a caller's bug, not a state.
    func start(_ request: CaptureStartRequest) async throws {
        switch request {
        case .stream(let filter, let configuration):
            try await start(filter: filter, configuration: configuration)

        case .synthetic:
            throw CaptureError.streamFailed("a stream cannot be started without a filter and a configuration")

        case .mosaic:
// Same shape, one level up: a mosaic is N streams, and the object that owns them is
// ``MosaicCompositor``. An engine handed this is a caller that has addressed the wrong object.
            throw CaptureError.streamFailed("a mosaic is started by the compositor that owns its streams, not by one stream")
        }
    }

/// Points a running stream at a different configuration, without stopping it.
///
/// This is what makes a mosaic's rearrangement cheap, and the reason is what a stop and a start
/// cost: a stream that is torn down and built again takes a second or more of black, and every tile
/// of a mosaic does it at once. Changing the size of the surface each tile is captured at is all an
/// arrangement of the same windows across a turn of the phone needs.
///
/// Nothing when there is no stream: a caller that reached here with nothing running is asking for a
/// change to a stream it does not have, and the next ``start(filter:configuration:)`` is what it
/// wants.
    func reconfigure(_ configuration: SCStreamConfiguration) async throws {
        let stream = lock.withLock { self.stream }
        guard let stream else { return }
        try await stream.updateConfiguration(configuration)
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
// Stop can fail when the stream has already died on its own, which is exactly how sleep/wake ends
// it, and there is nothing left to do about that.
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

// The status decides whether this sample buffer has a picture in it at all. `.complete` and
// `.started` do: `.started` is the first frame after the stream came up and carries real content,
// so dropping it is how a host that starts capturing a static screen shows the client nothing at
// all until something moves. `.idle` means the display did not change, which is not frame loss:
// frames are being delivered on schedule and there is simply nothing new in them. `.blank`,
// `.suspended` and `.stopped` carry no image either.
//
// An idle sample goes on to the pipeline rather than stopping here, which is the whole of why the
// pointer is choppy without it: with `showsCursor` off, a pointer moving over a screen where
// nothing is happening changes no pixel the stream is watching for, so an idle sample is all a
// fresh pointer could be built from.
//
// It is forwarded without its image buffer being looked at. A sample may have no buffer at all, and
// one that has a buffer has one the stream is going to reuse the moment this returns. What the
// pipeline is given is the fact that the screen did not change and where the content is; the
// picture comes from the overlay's own copy of the last frame. See ``IdleSample``.
        let info = Self.frameInfo(of: sampleBuffer)
        let status = info?.status

        guard status == .complete || status == .started else {
            // A sample with no status at all is one this side cannot classify: it may have carried a
            // picture that will now be dropped. It goes in its own counter rather than in `idle`,
            // which is the number that says a quiet stream is a working one. A sample with a status
            // is counted before anything else below, so every sample that is not a picture lands in
            // exactly one of the two counters however it is handled.
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

// The sample buffer's surface is only valid while the buffer is alive, and the encoder retains it
// for as long as it needs; CoreVideo keeps the IOSurface internally.
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

/// The stream died on its own. This is where sleep/wake and display changes arrive.
///
/// `-3821` (`systemStoppedStream`) is expected in normal use and is not a bug: closing the lid,
/// plugging in a monitor, or changing the resolution all end the stream. `-3801` (`userDeclined`)
/// means Screen Recording was never granted, or was revoked while the app was running. Both are
/// translated in ``CaptureError/from(_:)``.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let mapped = CaptureError.from(error)
        engineLog.error("stream stopped: \(mapped.errorDescription ?? "unknown", privacy: .public)")
        lock.withLock { self.stream = nil }
        onStop?(mapped)
    }

    // MARK: - Sample buffer decoding

/// Everything ScreenCaptureKit attaches to a frame.
///
/// Read from the sample attachments array, not from a buffer-level attachment, and the difference
/// between the two is an entire silent failure mode. ScreenCaptureKit records the frame's status,
/// content rect and scale in `CMSampleBufferGetSampleAttachmentsArray`, one dictionary per sample,
/// and attaches nothing at the buffer level, so a `CMGetAttachment` lookup answers `nil` for every
/// frame.
///
/// That would be harmless if the status were advisory. It is not: the status decides whether a
/// sample carries a picture, so a reader that always answers `nil` classifies every frame as one to
/// throw away. Capture starts, the stream runs at full rate and `startCapture()` never throws, and
/// not one frame is ever encoded, which is the symptom of a denied Screen Recording permission
/// reached from the opposite direction.
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
/// Two representations are in circulation and which one arrives depends on the key: an `NSValue`
/// wrapping a `CGRect`, and a dictionary from `CGRect.dictionaryRepresentation`. Guessing wrong
/// yields a `nil` rect, which is not an error anywhere and quietly degrades input mapping for
/// windows and applications, showing up as a cursor that drifts.
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
