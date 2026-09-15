import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

private let pipelineLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Capture and encode, as one thing the session can drive.
///
/// The session layer should not have to know that a stream and an encoder are two objects
/// with a lifetime between them — that a window resized past the encoder's dimensions needs
/// the encoder rebuilt, that a rebuilt encoder owes the client a keyframe, that a source
/// switch is really a teardown plus a setup plus a fresh keyframe. Those rules live here.
///
/// Everything runs on the capture queue that ``CaptureEngine`` delivers frames on, which is
/// serial. That is what makes the encoder swap below safe without a lock of its own.
///
/// A pipeline is built over one of two backends, and the difference is confined to how a
/// session starts: a real one reads the catalogue and builds a filter, a synthetic one
/// generates its own frames. Everything after that — the resize check, the encoder swap,
/// the keyframe bookkeeping, the statistics, the delivery of `EncodedFrame`s — is the same
/// code on both paths, which is what makes the synthetic path worth having. See
/// ``init(syntheticPixelSize:frameRate:codec:)``.
final class CapturePipeline: @unchecked Sendable {
    /// Where frames come from, and what starting one takes.
    ///
    /// Two cases rather than an optional resolver: the synthetic path must not merely skip
    /// the resolver, it must be unable to reach it. Everything ScreenCaptureKit would be
    /// asked for on this path — a catalogue, a filter, an `SCDisplay` — either fails or
    /// gets the process killed when Screen Recording has not been granted, and a path that
    /// cannot compile a call to them cannot be tempted into one.
    private enum Backend {
        case capture(resolver: CaptureSourceResolver, engine: CaptureEngine)
        case synthetic(engine: SyntheticCaptureEngine)
    }

    private let backend: Backend
    private let codec: VideoCodec
    /// The enlarged pointer, on the pipelines that were given one. Nil is a real state rather
    /// than a missing argument: the synthetic path has no screen for a pointer to be placed
    /// on, and a caller that is not the host window — the capture probe — has no preferences
    /// store to take one from. See ``CursorOverlay``.
    private let overlay: CursorOverlay?
    private let lock = NSLock()

    private var encoder: VideoEncoder?
    private var source: CaptureSource?
    /// Set when the client must be sent a keyframe before it can decode anything, and
    /// cleared when one goes out. Held here rather than only in the encoder because the
    /// encoder can be replaced mid-flight, and a request that dies with the old session
    /// leaves the client staring at a picture that never resolves.
    private var awaitsKeyframe = false

    private var _onFrame: (@Sendable (EncodedFrame) -> Void)?
    private var _onGeometry: (@Sendable (FrameGeometry) -> Void)?
    private var _onFailure: (@Sendable (CaptureError) -> Void)?

    /// Encoded frames, in order, on VideoToolbox's thread.
    var onFrame: (@Sendable (EncodedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// Where the captured content currently sits, reported per frame. A window that is
    /// dragged or resized changes this with no notification, so it is the only way the input
    /// mapping can stay correct for anything but a display.
    var onGeometry: (@Sendable (FrameGeometry) -> Void)? {
        get { lock.withLock { _onGeometry } }
        set { lock.withLock { _onGeometry = newValue } }
    }

    /// The stream stopped on its own — sleep/wake, a display change, a revoked permission.
    var onFailure: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onFailure } }
        set { lock.withLock { _onFailure = newValue } }
    }

    /// The source of frames, whichever kind it is.
    private var engine: any CaptureFrameSource {
        switch backend {
        case .capture(_, let engine): return engine
        case .synthetic(let engine): return engine
        }
    }

    init(resolver: CaptureSourceResolver, codec: VideoCodec = .h264, overlay: CursorOverlay? = nil) {
        self.backend = .capture(resolver: resolver, engine: CaptureEngine())
        self.codec = codec
        self.overlay = overlay
    }

    /// A pipeline that generates its own frames instead of capturing the screen.
    ///
    /// This is the seam that lets the real pipeline run where Screen Recording has not been
    /// granted — on CI, or on a machine whose grant cannot be obtained. `start(source:)`
    /// still has to be called, and still returns only once frames may begin arriving, but
    /// nothing on this path reads the catalogue, builds a filter, or constructs any
    /// ScreenCaptureKit object: the source it is handed is recorded rather than looked up.
    ///
    /// What it exercises is everything downstream of the stream, which is the reason it
    /// exists: the frame intake and its size check, the encoder rebuild when the surface
    /// changes size, the keyframe a rebuilt encoder owes, the statistics that combine
    /// stream and encoder counters, and the hand-off of `EncodedFrame`s to ``onFrame`` on a
    /// thread that is not the caller's. What it cannot exercise is ScreenCaptureKit itself
    /// — the pixel format and the content rect are generated rather than negotiated.
    ///
    /// - Parameters:
    ///   - syntheticPixelSize: The size to generate, in pixels. Rounded to even dimensions
    ///     the same way ``VideoEncoder`` rounds a capture size, so what arrives matches what
    ///     the encoder was built for.
    ///   - frameRate: Frames per second, fixed here rather than at `start`: the rate is part
    ///     of what the generator was built with, exactly as a stream's rate is part of its
    ///     configuration.
    init(syntheticPixelSize: CGSize, frameRate: Int = 60, codec: VideoCodec = .h264) {
        self.backend = .synthetic(
            engine: SyntheticCaptureEngine(pixelSize: syntheticPixelSize, frameRate: frameRate)
        )
        self.codec = codec
        // Generated frames describe no screen, so there is no coordinate space a pointer could
        // be placed in and none is looked for.
        self.overlay = nil
    }

    /// What is being captured, or `nil` while stopped.
    var currentSource: CaptureSource? {
        lock.withLock { source }
    }

    /// Everything worth knowing about a running session, in one value.
    ///
    /// Both halves are here because the failures they distinguish look identical from
    /// outside: a stream delivering nothing, a stream delivering frames the encoder drops,
    /// and an encoder that is simply not being fed are all "the client sees nothing".
    struct Statistics: Sendable, Equatable {
        /// Frames the stream delivered that carried a picture.
        ///
        /// **Not the number of frames the client received, and no longer a close stand-in
        /// for it.** The overlay can make a frame out of an idle sample — see
        /// ``idle(_:)`` — so on a still screen with the pointer moving this stays at
        /// whatever the display itself is doing while `framesEncoded` climbs at the frame
        /// rate. The pair answers "is the stream reporting", which is what it is for; the
        /// pair to read for "is the client getting frames" is this and `framesEncoded`
        /// together, not either one alone.
        let framesDelivered: Int
        /// Sample buffers that carried no new picture — a static display, a blank one, or a
        /// stopped stream. Not frame loss, and also not silence: every one of these is an
        /// opportunity for a frame the pointer moved in.
        let idleSamples: Int
        /// Frames handed to the network.
        let framesEncoded: Int
        /// Frames the encoder discarded because it could not keep up.
        let framesDropped: Int
    }

    var statistics: Statistics {
        let engineStatistics = engine.statistics
        let encoderStatistics = lock.withLock { encoder }?.statistics
        return Statistics(
            framesDelivered: engineStatistics.delivered,
            idleSamples: engineStatistics.idle,
            framesEncoded: encoderStatistics?.encoded ?? 0,
            framesDropped: encoderStatistics?.dropped ?? 0
        )
    }

    /// Where client coordinates map to for the active source, built from catalogue-time
    /// geometry. Prefer the per-frame content rect from ``onGeometry`` for windows and
    /// applications, whose content moves without anything announcing it.
    ///
    /// A synthetic pipeline answers ``InputTransform/degenerate``: generated frames are of
    /// no screen, so there is no coordinate space for a client's input to land in. The
    /// answer is still `nil` while stopped, so the shape of the answer does not depend on
    /// which backend is underneath.
    func inputTransform() -> InputTransform? {
        switch backend {
        case .capture(let resolver, _):
            return lock.withLock { source }.map { resolver.inputTransform(for: $0) }
        case .synthetic:
            return lock.withLock { source }.map { _ in .degenerate }
        }
    }

    /// Re-photographs the desktop showing on each display, ahead of the schedule.
    ///
    /// Detached rather than awaited: this is asked for by a client opening a panel, and what
    /// it is asking for arrives later and by another route — on the catalogue the host pushes
    /// when a picture lands. There is nothing here for the caller to wait for.
    ///
    /// A synthetic pipeline has no screen behind it and answers by doing nothing, the same way
    /// it answers ``inputTransform()`` with a degenerate transform.
    func refreshSpacePreviews() {
        guard case .capture(let resolver, _) = backend else { return }
        Task { await resolver.refreshSpacePreviews() }
    }

    /// A still of what is being streamed, or `nil` when nothing is.
    ///
    /// Asked for by the host window, which shows it. Deliberately not the frames the stream
    /// itself is made of: those arrive on the queue the whole capture depends on, and reaching
    /// into it to make a thumbnail would put this window's refresh rate in front of the phone's.
    ///
    /// A synthetic pipeline has no screen behind it and answers `nil`, the same way it answers
    /// ``inputTransform()`` with a degenerate transform.
    func snapshot(maxWidth: Int) async -> CGImage? {
        guard case .capture(let resolver, _) = backend,
              let source = lock.withLock({ source })
        else { return nil }
        return await resolver.snapshot(of: source, maxWidth: maxWidth)
    }

    /// The capture sources the host is currently offering.
    ///
    /// A synthetic pipeline has no sources and answers with an empty list rather than
    /// refusing. The caller is populating a picker, and "nothing to pick" is a true answer
    /// where an error would be a spurious one — there is no such thing as a generated source
    /// a client could ask for by name.
    func catalog() async throws -> CaptureCatalog {
        switch backend {
        case .capture(let resolver, _): return try await resolver.catalog()
        case .synthetic: return CaptureCatalog()
        }
    }

    // MARK: - Lifecycle

    /// Starts capturing a source, replacing whatever was being captured before.
    ///
    /// The catalogue is re-read first. The source came from the client, which chose it from
    /// a list that may be seconds old by the time a first frame is wanted: the window may
    /// have been closed, or the display unplugged. Failing here, with a message naming the
    /// source, is the difference between "the client cannot connect" and "the window you
    /// picked is gone".
    ///
    /// A synthetic pipeline takes the source as given — there is no catalogue to check it
    /// against and nothing to build a filter from — and uses the frame rate and the size it
    /// was built with, so neither of the parameters below reaches it. It cannot fail, which
    /// is deliberate: the caller that has to be able to run on a machine without Screen
    /// Recording permission is the caller that cannot afford an error here.
    ///
    /// - Parameters:
    ///   - frameRate: Frames per second to ask the stream for. It is passed to the encoder as
    ///     well as to the stream, and it has to be — the two are one number. See
    ///     ``CaptureFrameRate``.
    ///   - resolution: The size the surface is built at, which is the source's own unless it
    ///     is asked to be half. See ``CaptureResolution``.
    func start(
        source: CaptureSource,
        frameRate: Int = 60,
        resolution: CaptureResolution = .full
    ) async throws {
        await stop()

        switch backend {
        case .capture(let resolver, let engine):
            let catalog = try await resolver.catalog()
            guard let descriptor = catalog.all.first(where: { $0.source == source }) else {
                throw CaptureError.sourceUnavailable("That capture source is no longer available.")
            }

            let plan = try resolver.makeFilter(for: source)
            // One size, used twice, and it has to be the same expression both times.
            // ScreenCaptureKit delivers a surface of exactly the configured size, and the
            // encoder can encode nothing but a frame of its own — so a halved stream with a
            // full-sized encoder is not a slightly wrong picture, it is the resize check
            // below finding a different size on every frame and rebuilding the session and
            // its keyframe sixty times a second. See ``CapturePipeline/encode(_:)``.
            let pixelSize = resolution.pixelSize(for: descriptor.pixelSize)
            let configuration = try CaptureEngine.configuration(
                for: descriptor,
                pixelSize: pixelSize,
                frameRate: frameRate
            )
            // Set after the configuration is built rather than inside it: the rectangle belongs
            // to the filter — it is expressed in that filter's coordinate space — and
            // `CaptureEngine` is handed only a descriptor. See ``CaptureFilterPlan``.
            if let sourceRect = plan.sourceRect {
                configuration.sourceRect = sourceRect
            }
            // Keep the system pointer in the capture even when the overlay draws the larger
            // one over it. Cursor movement is then a real display change, so ScreenCaptureKit
            // produces a real picture at the requested cadence instead of a run of `.idle`
            // samples. The larger opaque pointer covers the smaller one at the same tip.
            //
            // Hiding it here made remote pointer movement arrive at only the rate some other
            // part of the screen happened to change (measured at 1–21 fps). Manufacturing
            // pictures from idle samples was not equivalent: those pictures could break the
            // decoder's reference chain. Keeping the system cursor visible gives the encoder
            // genuine consecutive frames and measured 56 fps over a 60 fps stream.
            configuration.showsCursor = true
            let encoder = try VideoEncoder(codec: codec, pixelSize: pixelSize, frameRate: frameRate)

            try await begin(
                engine: engine,
                request: .stream(filter: plan.filter, configuration: configuration),
                encoder: encoder,
                source: source
            )
            // The size is logged as well as the title, because the two ways a stream can be
            // built here — the source's own size and half of it — are otherwise
            // indistinguishable from the log, and "which one was that run" is the whole
            // question when someone is comparing them.
            pipelineLog.notice("""
                capturing \(descriptor.title, privacy: .public) at \
                \(Int(pixelSize.width), privacy: .public)×\
                \(Int(pixelSize.height), privacy: .public) \
                @ \(frameRate, privacy: .public) fps
                """)

        case .synthetic(let engine):
            if frameRate != engine.frameRate {
                pipelineLog.notice("""
                    synthetic pipeline was built for \(engine.frameRate, privacy: .public) fps; \
                    the \(frameRate, privacy: .public) fps asked for here is ignored
                    """)
            }
            let encoder = try VideoEncoder(
                codec: codec,
                pixelSize: engine.pixelSize,
                frameRate: engine.frameRate
            )

            try await begin(engine: engine, request: .synthetic, encoder: encoder, source: source)
            pipelineLog.notice("""
                generating \(Int(engine.pixelSize.width), privacy: .public)×\
                \(Int(engine.pixelSize.height), privacy: .public) frames \
                @ \(engine.frameRate, privacy: .public) fps
                """)
        }
    }

    /// Wires a source and an encoder to each other and starts the source.
    ///
    /// Shared by both backends, so neither can drift from the other's ordering. The order
    /// matters at two points: the callbacks are attached before the source is started, or
    /// the first frames of a session have nowhere to go; and the keyframe is asked for
    /// after it, because a request made before there is a session to make it on is lost —
    /// the first frame of a session must be a keyframe, since a client joining mid-stream
    /// has no parameter sets and nothing to decode against.
    private func begin(
        engine: any CaptureFrameSource,
        request: CaptureStartRequest,
        encoder: VideoEncoder,
        source: CaptureSource
    ) async throws {
        // Copyable because a `let` existential's settable properties cannot be assigned to,
        // even when every conforming type is a class.
        var engine = engine

        lock.withLock {
            self.source = source
            self.encoder = encoder
            self.awaitsKeyframe = true
        }
        encoder.onFrame = { [weak self] encoded in self?.deliver(encoded) }
        encoder.onFailure = { [weak self] error in self?.report(error) }

        engine.onFrame = { [weak self] frame in self?.ingest(frame) }
        engine.onIdle = { [weak self] sample in self?.idle(sample) }
        engine.onStop = { [weak self] error in self?.report(error) }

        do {
            try await engine.start(request)
        } catch {
            await stop()
            throw error
        }

        encoder.requestKeyframe()
    }

    func stop() async {
        await engine.stop()
        let encoder = lock.withLock { () -> VideoEncoder? in
            let current = self.encoder
            self.encoder = nil
            self.source = nil
            self.awaitsKeyframe = false
            return current
        }
        encoder?.shutdown()
    }

    /// Forces the next frame to be a keyframe, whenever that frame arrives.
    ///
    /// This is what a new client connection calls. It does not wait for the two-second
    /// keyframe interval, and it does not tear the session down to get one.
    func requestKeyframe() {
        let encoder = lock.withLock { () -> VideoEncoder? in
            awaitsKeyframe = true
            return self.encoder
        }
        encoder?.requestKeyframe()
    }

    /// Changes the bitrate on the running encoder. Also arms a keyframe request so the new
    /// rate takes effect quickly rather than waiting for the two-second interval.
    func setBitrate(_ bitsPerSecond: Int) {
        let encoder = lock.withLock { self.encoder }
        encoder?.setBitrate(bitsPerSecond)
        encoder?.requestKeyframe()
    }

    // MARK: - Frame flow

    /// A captured frame, on the capture queue.
    private func ingest(_ frame: CapturedFrame) {
        onGeometry?(frame.geometry)

        // The last point at which the frame is still this app's to draw on. After the encoder
        // the buffer belongs to VideoToolbox, and this is also the only place that holds both
        // the frame and the geometry saying where its content sits on screen, which is what
        // placing a pointer takes. Silent when there is no overlay, and when the overlay
        // decides not to draw — see ``CursorOverlay/draw(into:geometry:)``.
        overlay?.draw(into: frame.pixelBuffer, geometry: frame.geometry)

        encode(frame)
    }

    /// A sample that carried no new picture, on the capture queue.
    ///
    /// **Where the pointer's smoothness comes from.** On a screen where nothing is
    /// happening, the pointer is the only thing that moves, and with `showsCursor` off
    /// nothing about it reaches the stream — so every sample is idle, nothing is encoded,
    /// and the pointer can only move as often as the display changes for some other reason.
    /// The overlay turns the pointer's own movement into a frame; this is where it is asked.
    ///
    /// An idle sample is otherwise worth nothing — it is the picture the client already has,
    /// and sending one per sample would be a stream of identical frames — so when the
    /// overlay cannot make anything of it (it is off, the pointer is over something else, it
    /// has no picture of its own to draw on yet, or the encoder has not finished with the
    /// buffer) the sample goes exactly where it went before this existed: nowhere.
    ///
    /// ``onGeometry`` is deliberately not told about these. An idle sample's idea of where
    /// the content sits can be emptier than a frame's — nothing about one is promised except
    /// that the screen has not changed — and the mapping the client's input goes through is
    /// built from the last frame that actually reported one. Letting a sparser answer
    /// overwrite a good one would move the pointer and the taps apart.
    private func idle(_ sample: IdleSample) {
        guard Self.idleFramesEnabled else { return }
        guard let overlay, let frame = overlay.redraw(sample) else { return }
        encode(frame)
    }

    /// Whether an idle sample is allowed to become a frame.
    ///
    /// **Off, and the switch is here rather than deleted so the reasoning survives.**
    ///
    /// The idea is sound and measurably works in isolation — modelled against a real
    /// `VTCompressionSession` it turns a still screen into sixty frames a second for one
    /// whole-picture copy. On the device it does the opposite. With it on, the rate sits around
    /// thirty until the pointer is touched and then collapses to about one, which is the
    /// signature of the *client* refusing what this path invents: the first synthetic frame
    /// fails to decode, the renderer resets and latches onto awaiting-a-keyframe, and from then
    /// on the only pictures that get through are the keyframes, one every two seconds.
    ///
    /// So whatever is wrong is in what these frames *are* rather than in the idea: a timestamp,
    /// an attachment, or a reference to a picture the decoder never had. That is a diagnosis to
    /// make against a running system, not by reading, and until it is made the honest place for
    /// this is off — a choppy pointer is a disappointment, and one frame every two seconds with
    /// the picture freezing under your finger is a broken app.
    private static let idleFramesEnabled = false

    /// Hands a frame of this pipeline's own making to the encoder.
    ///
    /// Sharing this with the idle path rather than letting that path reach the encoder
    /// directly is what keeps the two from drifting: a frame the overlay drew a pointer into
    /// and a frame the overlay built out of an idle sample are the same thing from here on,
    /// and both go through the resize check and the keyframe bookkeeping.
    private func encode(_ frame: CapturedFrame) {
        // The stream's surface changes size when a captured window is resized — the stream
        // keeps producing frames at the new size, but the session was created for the old
        // one and cannot encode a frame of a different size at all. Rebuilding is the only
        // option, and it costs the client a keyframe, so it happens on the size *changing*
        // rather than on every frame.
        let size = VideoEncoder.encodedSize(
            for: CGSize(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
        )

        let encoder: VideoEncoder
        let current = lock.withLock { self.encoder }
        if let current, current.pixelSize == size {
            encoder = current
        } else {
            do {
                encoder = try rebuildEncoder(for: size, replacing: current)
            } catch {
                report(error as? CaptureError ?? .encodingFailed("\(error)"))
                return
            }
        }

        do {
            try encoder.encode(frame)
        } catch {
            report(error as? CaptureError ?? .encodingFailed("\(error)"))
        }
    }

    /// Must be called on the capture queue, where it is the only writer.
    ///
    /// Built for the size the *surface* is now, never for the size the stream was configured
    /// with. At half resolution those two differ for a captured window: the stream is
    /// configured at half the window's size, and a window grown past that produces a surface
    /// of its own size again. The replacement keeps up with the frames rather than with the
    /// setting — an encoder that insisted on half would be encoding a size the frames are
    /// not — so the halving comes back with the next capture, which is the same moment it is
    /// applied at in the first place.
    private func rebuildEncoder(for size: CGSize, replacing current: VideoEncoder?) throws -> VideoEncoder {
        let replacement = try VideoEncoder(
            codec: codec,
            pixelSize: size,
            frameRate: current?.frameRate ?? 60
        )
        replacement.onFrame = { [weak self] encoded in self?.deliver(encoded) }
        replacement.onFailure = { [weak self] error in self?.report(error) }

        // A new session has no keyframe that a decoder following the old one can use, so one
        // is owed whether or not the session asked for it.
        lock.withLock {
            encoder = replacement
            awaitsKeyframe = true
        }
        // Shut down only after the swap, so nothing can hand a frame to a dead session.
        current?.shutdown()

        pipelineLog.notice("""
            capture surface resized to \(Int(size.width), privacy: .public)×\
            \(Int(size.height), privacy: .public) · encoder rebuilt
            """)
        return replacement
    }

    /// An encoded frame, on VideoToolbox's thread.
    private func deliver(_ encoded: EncodedFrame) {
        if encoded.isKeyframe {
            lock.withLock { awaitsKeyframe = false }
        }
        let consumer = lock.withLock { _onFrame }
        consumer?(encoded)
    }

    /// Hands a failure to the session, on whatever thread produced it.
    ///
    /// A stream that stopped is not torn down here. The session decides: sleeping and waking
    /// should restart the stream, while a revoked permission should put an explanation on
    /// screen, and only the session knows which one it is looking at.
    private func report(_ error: CaptureError) {
        let failure = lock.withLock { _onFailure }
        failure?(error)
    }
}
