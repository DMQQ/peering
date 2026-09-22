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
/// **This is a frame and not a sample.** Everything that is not a picture the display just
/// changed to is an ``IdleSample`` and travels by its own route — including the idle samples
/// that happen to carry an image buffer, because a receipt that sometimes arrives is worse
/// to build on than one that never does.
///
/// `@unchecked Sendable` because it carries a `CVPixelBuffer`, which is a CoreVideo
/// reference type the compiler cannot prove safe to move between threads. It is safe in
/// practice for the one hop that matters here: the buffer is delivered once, handed to
/// VideoToolbox, and never touched again — and VideoToolbox retains it for as long as it
/// needs it, which is why the encoder may return before the frame has been read.
///
/// That last sentence is why ``CursorOverlay/redraw(_:)`` keeps a buffer of its own rather
/// than drawing into the frame it sent last. "Never touched again" is a promise this struct
/// makes on the receiving side, and nothing here can keep it — the buffer belongs to a pool
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

extension FrameGeometry {
    /// The input transform this frame implies, or `nil` when the frame does not describe one.
    ///
    /// Built from `screenRect` rather than `contentRect` on purpose. `InputTransform` wants a
    /// top-left in the *global* point space `CGEvent` posts into, and `contentRect` is in the
    /// stream surface's own coordinates — a third space again, offset by wherever the surface
    /// sits. `screenRect` is already the answer, which is why it travels with every frame.
    ///
    /// `screenRect` is points and `InputTransform.pixelSize` is pixels, so the same
    /// `scaleFactor` that converts one to the other is also the `pointPixelScale` — exactly as
    /// ``DisplayGeometry`` builds it for a display.
    ///
    /// **A halved stream maps input exactly as a full one does, and this is where that is
    /// either true or not.** See ``CaptureResolution``: the surface can be configured at half
    /// the size it would otherwise have, which puts a quarter of the pixels in every frame.
    /// Neither value this is built from moves when it is, and that is measured rather than
    /// assumed. On this 2× panel, a stream configured at 756×491 reports `scaleFactor` 2.0 and
    /// `screenRect` (0,0 1512×982) — the same two values a stream at 1512×982 reports — while
    /// `contentRect` halves to 378×245.5 and `contentScale` quarters to 0.25. So the factor
    /// belongs to the *display*, not to the surface that happens to be carrying it, which is
    /// what the SDK's own words for the key say: "the display resolution associated with the
    /// frame. Display resolution is the pixel to point scaling factor." `screenRect` is where
    /// the content sits *on screen*, in the window server's global points, and a smaller
    /// surface is still a view onto the same rectangle of screen. The two values that do move
    /// with the surface are `contentRect` and `contentScale`, and nothing in this app reads
    /// either of them.
    ///
    /// The halving could not slip past this even if a later macOS answered with the surface's
    /// factor instead: `pixelSize` and `pointPixelScale` are both built from it, and
    /// ``InputTransform/globalPoint(fromNormalized:)`` multiplies by one and divides by the
    /// other, so both directions of the mapping collapse to the same function of `screenRect`
    /// — `origin + normalized × screenRect.size` — whatever the factor is. The pointer lands
    /// under the finger at half size for the same reason it does at full size.
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
/// **Not to be confused with `SCStreamConfiguration.captureResolution`**, which is
/// ScreenCaptureKit's choice of what the system composites at and stays `.nominal` either
/// way. This is the size of the surface that comes out.
///
/// A setting rather than a constant because the size of the picture is the one lever that
/// moves every cost in the pipeline at once — compositing, the colour conversion, the
/// encode, and the bitrate that fits in the link — and the machine on the other end of that
/// link is a phone. `half` is the lever's whole travel: a quarter of the pixels, which is
/// the smallest change big enough to be worth a switch.
enum CaptureResolution: String, CaseIterable, Sendable {
    /// The size the source reports — what every stream before this setting existed was built
    /// at, and still the default.
    case full

    /// Three-quarters the width and height, so about 56% of the pixels.
    case threeQuarters

    /// Half the width and half the height, so a quarter of the pixels.
    case half

    /// The size a stream is built at for a source whose own size is `native`.
    ///
    /// **Half of the size the stream would otherwise be built at**, rather than half of the
    /// panel's hardware pixels, and on this Mac those are not the same number. A descriptor's
    /// `pixelSize` for a display comes from `CGDisplayPixelsWide`, which reports 1512×982 for
    /// a panel whose real pixels are 3024×1964 — it answers with the display *mode's* width,
    /// which is points. Halving whatever the stream would have been configured with is the
    /// one rule that holds for all three kinds of source, in whatever units each of them
    /// happens to be in, and the one that keeps this setting about *this stream*: `full` is
    /// byte for byte the configuration every earlier version of this app built, and `half` is
    /// exactly half of it.
    ///
    /// Odd dimensions are left odd rather than rounded here: the stream rounds to the nearest
    /// point and ``VideoEncoder`` rounds down to even, and both of those have to happen in
    /// that order for the encoder's size to match the surface's. See
    /// ``CapturePipeline/encode(_:)``.
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
/// Two values rather than a number, because the rate is not a free parameter: it is set on
/// the stream as a minimum frame interval and on the encoder as its timeline, and the two
/// have to be the same number or the encoder codes frames against a clock it was not told
/// about. An enum is what makes them the same number — there is one of these values per
/// capture and both halves are built from it.
///
/// `oneTwenty` only ever gets frames from a display that refreshes faster than 60 times a
/// second: the interval is a ceiling, not a promise, and a panel that cannot go that fast
/// delivers what it can and no more.
enum CaptureFrameRate: Int, CaseIterable, Sendable {
    case thirty = 30
    case sixty = 60
    case oneTwenty = 120
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
    private var _onIdle: (@Sendable (IdleSample) -> Void)?
    private var _onStop: (@Sendable (CaptureError) -> Void)?
    private var _onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    private var capturesAudio = false

    /// Counters for the two questions a silent capture failure raises: is the stream alive
    /// at all, and is it alive but with nothing to send?
    ///
    /// The distinction matters because they have different causes. No frames and no idle
    /// samples is a stream that was never really started — usually a denied Screen Recording
    /// permission, which produces no error anywhere. A stream that reports idle samples is
    /// working perfectly and the display simply is not changing.
    ///
    /// **What these two describe is the stream, not the client's screen.** `delivered` counts
    /// samples that carried a picture and `idle` counts everything else, and neither says how
    /// many frames were encoded or sent: an idle sample can now become a frame of its own —
    /// see ``CursorOverlay/redraw(_:)`` — so a host whose pointer is moving over a still
    /// screen reports a large `idle` and a healthy stream of frames at the same time, and
    /// that is not a contradiction. What the pair is for is telling a stream that is
    /// reporting from one that is not, and that is unaffected by anything downstream of here.
    /// The count of frames that actually reached the client is
    /// ``CapturePipeline/Statistics/framesEncoded``, which is a different question with a
    /// different answer.
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

    /// Called for every sample that carries no new picture, on the capture queue.
    var onIdle: (@Sendable (IdleSample) -> Void)? {
        get { lock.withLock { _onIdle } }
        set { lock.withLock { _onIdle = newValue } }
    }

    /// Called when the stream stops by itself — sleep/wake, a display change, or the user
    /// revoking Screen Recording mid-session. Not called for a stop this object initiated.
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
    ///   the size the configuration is built with: the source's own, or half of it. See
    ///   ``CaptureResolution``.
    /// - `backgroundColor` — set to opaque black explicitly. The default is *clear*, and a
    ///   clear backdrop over anything that is not a full display (an application filter, or
    ///   a window smaller than its surface) composites to whatever the surface had in it:
    ///   uninitialised garbage.
    /// - `showsCursor` — off. The iPhone renders the commanded pointer immediately, removing
    ///   one video round trip and avoiding a second cursor baked into the picture.
    ///
    /// Two properties are deliberately left alone. `scalesToFit` is not set: it stretches
    /// content to the configured size, which is how a window capture ends up with the wrong
    /// aspect ratio in a client window of a different shape. And neither `colorSpaceName`
    /// nor `colorMatrix` is set — a stream tagged with a colour space the client does not
    /// expect is a stream that decodes with a green or washed-out cast, and the default
    /// matches what the `420v` format already implies. (Note the property is
    /// `colorSpaceName`; there is no `colorSpace` on `SCStreamConfiguration`.)
    ///
    /// - Parameter pixelSize: The size of the surface to ask for, which is the source's own
    ///   or half of it — passed in rather than read off the descriptor because at half
    ///   resolution the stream is deliberately not the size the source is, and the caller is
    ///   the one that decided that. See ``CaptureResolution/pixelSize(for:)``.
    /// - Parameter showsCursor: Whether ScreenCaptureKit draws the pointer into this stream.
    ///   `false` everywhere except a mosaic's tiles, where the pointer is a real pointer in a
    ///   real window and the alternative — the overlay this app draws itself — has no single
    ///   screen rectangle to place one in. See ``MosaicCompositor``.
    static func configuration(
        for descriptor: CaptureSourceDescriptor,
        pixelSize: CGSize,
        frameRate: Int,
        showsCursor: Bool = false
    ) throws -> SCStreamConfiguration {
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())

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
        configuration.showsCursor = showsCursor

        // Caps the capture rate rather than the encode rate, and it is the stream's half of
        // ``CaptureFrameRate`` — the encoder is built with the same number, because the two
        // have to agree. The encoder codes frames against a clock, and a stream whose
        // interval says 120 while its encoder was told 60 is a timeline that stutters rather
        // than one that fails, which is a bug with no error attached to it. A panel that
        // cannot go this fast delivers what it can and no more.
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

        case .mosaic:
            // Same shape, one level up: a mosaic is N streams, and the object that owns them
            // is ``MosaicCompositor``. An engine handed this is a caller that has addressed the
            // wrong object, and saying so is better than starting nothing in silence.
            throw CaptureError.streamFailed("a mosaic is started by the compositor that owns its streams, not by one stream")
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

        // The status decides whether this sample buffer has a picture in it at all.
        //
        // `.complete` and `.started` do. `.started` is the first frame after the stream
        // came up, and it carries real content — dropping it is how a host that starts
        // capturing a static screen shows the client nothing at all until something moves.
        //
        // `.idle` means the display did not change, which is *not* frame loss: frames are
        // being delivered on schedule and there is simply nothing new in them. `.blank`
        // (display asleep), `.suspended` and `.stopped` carry no image either.
        //
        // An idle sample goes on to the pipeline rather than stopping here, and it is the
        // whole of why the pointer is choppy without it: on a screen where nothing is
        // happening the pointer is the only thing that moves, and with `showsCursor` off it
        // does not change a single pixel the stream is watching for. An idle sample is all
        // that arrives, so it is all a fresh pointer could be built from.
        //
        // **It is forwarded without its image buffer being looked at, and that is the
        // point.** A frame cannot be made from these pixels — a sample may have no buffer at
        // all, which is how this path used to be killed before it ran, and a sample that has
        // one has a buffer the stream is going to reuse the moment this returns. What the
        // pipeline is given is the fact that the screen did not change and where the content
        // is; the picture comes from the overlay's own copy of the last frame. See
        // ``IdleSample``.
        let info = Self.frameInfo(of: sampleBuffer)
        let status = info?.status

        guard status == .complete || status == .started else {
            // Counted before anything else, so every sample that is not a picture lands in
            // exactly one of the two counters however it is handled below. A stream
            // reporting idle samples is working perfectly and the display is simply not
            // changing; a stream reporting neither is one that was never really started —
            // usually a denied Screen Recording permission, which produces no error
            // anywhere. Folding idle samples into `delivered` would erase the only evidence
            // that tells those two apart, so it is not done even though an idle sample can
            // now become a frame.
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

        // The sample buffer's surface is only valid while the buffer is alive, and the
        // encoder retains it for as long as it needs; CoreVideo keeps the IOSurface
        // internally, so the reference can be handed straight on.
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
