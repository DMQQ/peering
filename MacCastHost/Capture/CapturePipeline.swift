import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

private let pipelineLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Capture and encode, as one thing the session can drive.
///
/// The session layer should not have to know that a stream and an encoder are two objects with a
/// lifetime between them: that a window resized past the encoder's dimensions needs the encoder
/// rebuilt, that a rebuilt encoder owes the client a keyframe, that a source switch is really a
/// teardown plus a setup plus a fresh keyframe. Those rules live here.
///
/// Everything runs on the capture queue ``CaptureEngine`` delivers frames on, which is serial, and
/// that is what makes the encoder swap safe without a lock of its own.
///
/// The difference between the two backends is confined to how a session starts; everything after
/// that is the same code on both paths, which is what makes the synthetic path worth having. See
/// ``init(syntheticPixelSize:frameRate:codec:)``.
final class CapturePipeline: @unchecked Sendable {
/// Where frames come from, and what starting one takes.
///
/// Two cases rather than an optional resolver: the synthetic path must not merely skip the resolver,
/// it must be unable to reach it. Everything ScreenCaptureKit would be asked for on this path fails
/// or gets the process killed when Screen Recording has not been granted.
    private enum Backend {
/// A real Mac's sources: one at a time, or several drawn into one canvas.
///
/// Both live here rather than one per backend, because they are the same session. A mosaic is a
/// capture source like any other, asked for with the same command, and selecting one of its tiles is
/// an ordinary source switch. The compositor is built alongside the engine and does nothing at all
/// until a mosaic is started on it.
        case capture(resolver: CaptureSourceResolver, engine: CaptureEngine, compositor: MosaicCompositor)
        case synthetic(engine: SyntheticCaptureEngine)
    }

    private let backend: Backend
    private let codec: VideoCodec
/// The enlarged pointer, on the pipelines that were given one. Nil is a real state rather than a
/// missing argument: the synthetic path has no screen for a pointer to be placed on, and a caller
/// that is not the host window has no preferences store to take one from. See ``CursorOverlay``.
    private let overlay: CursorOverlay?
    private let lock = NSLock()

    private var encoder: VideoEncoder?
    private var source: CaptureSource?
/// Set when the client must be sent a keyframe before it can decode anything, and cleared when one
/// goes out. Held here rather than only in the encoder because the encoder can be replaced
/// mid-flight, and a request that dies with the old session leaves the client staring at a picture
/// that never resolves.
    private var awaitsKeyframe = false

    private var _onFrame: (@Sendable (EncodedFrame) -> Void)?
    private var _onGeometry: (@Sendable (FrameGeometry) -> Void)?
    private var _onFailure: (@Sendable (CaptureError) -> Void)?
    private var _onAudio: (@Sendable (CMSampleBuffer) -> Void)?

    /// Encoded frames, in order, on VideoToolbox's thread.
    var onFrame: (@Sendable (EncodedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// Raw audio sample buffers from the SCStream. Only fires when audio capture was enabled
    /// on the engine before the stream started.
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)? {
        get { lock.withLock { _onAudio } }
        set { lock.withLock { _onAudio = newValue } }
    }

    /// Where the captured content currently sits, reported per frame. A window that is
    /// dragged or resized changes this with no notification, so it is the only way the input
    /// mapping can stay correct for anything but a display.
    var onGeometry: (@Sendable (FrameGeometry) -> Void)? {
        get { lock.withLock { _onGeometry } }
        set { lock.withLock { _onGeometry = newValue } }
    }

/// The stream stopped on its own: sleep/wake, a display change, a revoked permission.
    var onFailure: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onFailure } }
        set { lock.withLock { _onFailure = newValue } }
    }

/// The source that is running, which on a capture pipeline is one of two.
///
/// Held rather than derived: the engine and the compositor are both alive for the life of the
/// pipeline, and only the last ``start(source:frameRate:resolution:)`` says which of them the
/// session is currently reading. Nil while stopped; see ``engine``.
    private var runningEngine: (any CaptureFrameSource)?

    /// Whether the session in flight is a canvas rather than a single source.
    ///
    /// Read from the recorded source rather than from the running engine, because the answer is
    /// needed on the frame path where taking the lock for it would be one more lock in the
    /// hottest code in the host.
    private var isMosaic: Bool { lock.withLock { source }?.isMosaic ?? false }

    /// The arrangement whose captures are still running behind the window on screen.
    ///
    /// Set when the pipeline leaves a mosaic for one of its own tiles, and cleared when it comes
    /// back or goes anywhere else. It cannot be read from ``runningEngine``, which by then is the
    /// window's engine. See ``releaseRunningSource(keepingMosaicFor:)``.
    private var parkedMosaic: MosaicCompositor?

    /// The source of frames, whichever kind it is, and whichever of the two it is.
    private var engine: any CaptureFrameSource {
        if let runningEngine { return runningEngine }
        switch backend {
        case .capture(_, let engine, _): return engine
        case .synthetic(let engine): return engine
        }
    }

    init(resolver: CaptureSourceResolver, codec: VideoCodec = .h264, overlay: CursorOverlay? = nil) {
        self.backend = .capture(
            resolver: resolver,
            engine: CaptureEngine(),
            compositor: MosaicCompositor()
        )
        self.codec = codec
        self.overlay = overlay
    }

/// A pipeline that generates its own frames instead of capturing the screen.
///
/// The seam that lets the real pipeline run where Screen Recording has not been granted. `start(source:)`
/// still has to be called, and still returns only once frames may begin arriving, but nothing on this
/// path reads the catalogue, builds a filter, or constructs any ScreenCaptureKit object: the source
/// it is handed is recorded rather than looked up.
///
/// What it exercises is everything downstream of the stream: the frame intake and its size check, the
/// encoder rebuild when the surface changes size, the keyframe a rebuilt encoder owes, the statistics
/// that combine stream and encoder counters, and the hand-off of `EncodedFrame`s on a thread that is
/// not the caller's. What it cannot exercise is ScreenCaptureKit itself.
///
/// - Parameters:
///   - syntheticPixelSize: The size to generate, in pixels. Rounded to even dimensions the same way
///     ``VideoEncoder`` rounds a capture size, so what arrives matches what the encoder was built
///     for.
///   - frameRate: Frames per second, fixed here rather than at `start`: the rate is part of what the
///     generator was built with, exactly as a stream's rate is part of its configuration.
    init(syntheticPixelSize: CGSize, frameRate: Int = 60, codec: VideoCodec = .h264) {
        self.backend = .synthetic(
            engine: SyntheticCaptureEngine(pixelSize: syntheticPixelSize, frameRate: frameRate)
        )
        self.codec = codec
// Generated frames describe no screen, so there is no coordinate space a pointer could be placed
// in and none is looked for.
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
/// Not the number of frames the client received. The overlay can make a frame out of an idle sample
/// (see ``idle(_:)``), so on a still screen with the pointer moving this stays at whatever the
/// display itself is doing while `framesEncoded` climbs at the frame rate. The pair answers "is the
/// stream reporting"; the pair to read for "is the client getting frames" is this and
/// `framesEncoded` together.
        let framesDelivered: Int
        /// Sample buffers that carried no new picture: a static display, a blank one, or a
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

/// Where client coordinates map to for the active source, built from catalogue-time geometry.
/// Prefer the per-frame content rect from ``onGeometry`` for windows and applications, whose content
/// moves without anything announcing it.
///
/// A synthetic pipeline answers ``InputTransform/degenerate``: generated frames are of no screen, so
/// there is no coordinate space for a client's input to land in. The answer is still `nil` while
/// stopped, so the shape of the answer does not depend on which backend is underneath.
    func inputTransform() -> InputTransform? {
        switch backend {
        case .capture(let resolver, _, _):
// The resolver answers ``InputTransform/degenerate`` for a mosaic, which is the honest answer: a
// tile under a tap decides which machine coordinate it means, and the host refuses input outright
// while a mosaic is up. When the client has selected a tile, this is that tile's transform.
            return lock.withLock { source }.map { resolver.inputTransform(for: $0) }
        case .synthetic:
            return lock.withLock { source }.map { _ in .degenerate }
        }
    }

/// Re-photographs the desktop showing on each display, ahead of the schedule.
///
/// Detached rather than awaited: this is asked for by a client opening a panel, and what it is asking
/// for arrives later and by another route, on the catalogue the host pushes when a picture lands.
/// A synthetic pipeline has no screen behind it and answers by doing nothing.
    func refreshSpacePreviews() {
        guard case .capture(let resolver, _, _) = backend else { return }
        Task { await resolver.refreshSpacePreviews() }
    }

/// Photographs every running application, for a client drawing the picker's grid.
///
/// Detached on exactly the terms above: the pictures come back on the catalogue push.
    func refreshSourceThumbnails() {
        guard case .capture(let resolver, _, _) = backend else { return }
        Task { await resolver.refreshSourceThumbnails() }
    }

/// A still of what is being streamed, or `nil` when nothing is.
///
/// Asked for by the host window, which shows it. Deliberately not the frames the stream itself is
/// made of: those arrive on the queue the whole capture depends on, and reaching into it to make a
/// thumbnail would put this window's refresh rate in front of the phone's.
///
/// A synthetic pipeline has no screen behind it and answers `nil`.
    func snapshot(maxWidth: Int) async -> CGImage? {
        guard case .capture(let resolver, _, _) = backend,
              let source = lock.withLock({ source }),
// A canvas is not a source anything can photograph: it exists only as the frames this pipeline
// composites. The host window shows nothing rather than a picture of one window pretending to be the
// mosaic.
              !source.isMosaic
        else { return nil }
        return await resolver.snapshot(of: source, maxWidth: maxWidth)
    }

/// The capture sources the host is currently offering.
///
/// A synthetic pipeline has no sources and answers with an empty list rather than refusing: the
/// caller is populating a picker, and "nothing to pick" is a true answer where an error would be a
/// spurious one.
    func catalog() async throws -> CaptureCatalog {
        switch backend {
// The same catalogue either way, and deliberately not a filtered one while a mosaic is up: the
// client choosing a tile to focus is looking at exactly this list, and a Mac that stopped offering
// its windows because a canvas is on screen would be a picker that empties itself the moment it is
// used.
        case .capture(let resolver, _, _): return try await resolver.catalog()
        case .synthetic: return CaptureCatalog()
        }
    }

    // MARK: - Lifecycle

/// Starts capturing a source, replacing whatever was being captured before.
///
/// The catalogue is re-read first. The source came from the client, which chose it from a list that
/// may be seconds old by the time a first frame is wanted: the window may have been closed, or the
/// display unplugged. Failing here, with a message naming the source, is the difference between "the
/// client cannot connect" and "the window you picked is gone".
///
/// A synthetic pipeline takes the source as given and uses the frame rate and the size it was built
/// with, so neither of the parameters below reaches it. It cannot fail, which is deliberate: the
/// caller that has to be able to run without Screen Recording permission is the caller that cannot
/// afford an error here.
///
/// - Parameters:
///   - frameRate: Frames per second to ask the stream for. It is passed to the encoder as well as to
///     the stream, and it has to be: the two are one number. See ``CaptureFrameRate``.
///   - resolution: The size the surface is built at, which is the source's own unless it is asked to
///     be half. See ``CaptureResolution``.
    func start(
        source: CaptureSource,
        frameRate: Int = 60,
        resolution: CaptureResolution = .full
    ) async throws {
// Before the stop, because the captures are the thing being kept. A mosaic asked for again with the
// same windows in different rectangles is the same six captures drawn somewhere else, and stopping
// them first is what made that change cost a second and a half of black. See ``recompose(_:)``.
        if await recompose(source) { return }

        await releaseRunningSource(keepingMosaicFor: source)

        switch backend {
        case .capture(let resolver, let engine, let compositor):
// A mosaic is a source, not a backend. It is asked for with the same command as anything else, and
// leaving it for one of its tiles is an ordinary source switch.
            if case .mosaic(let requested) = source {
                guard let layout = requested.validated, !layout.tiles.isEmpty else {
                    throw CaptureError.sourceUnavailable("That mosaic has no windows in it.")
                }
                let catalog = try await resolver.catalog()
                let plan = MosaicPlan.make(layout: layout, catalog: catalog, resolver: resolver)
                guard !plan.tiles.isEmpty else {
                    throw CaptureError.sourceUnavailable(
                        "None of the windows in this mosaic are still open."
                    )
                }
// A window that went before the canvas was built is one the phone is still drawing an outline
// around. The list is marked stale so the catalogue that follows says it has gone.
                if plan.tiles.count < layout.tiles.count {
                    pipelineLog.notice("""
                        \(layout.tiles.count - plan.tiles.count, privacy: .public) of \
                        \(layout.tiles.count, privacy: .public) windows in this mosaic have gone
                        """)
                    resolver.invalidate()
                }
// Built for the canvas, at the canvas's own rate, and not through ``CaptureResolution``: the client's
// rectangles describe a picture it chose the size of, so halving it here would draw every tile into a
// canvas nobody asked for. The host window's resolution setting therefore does nothing while a mosaic
// is up.
                let encoder = try VideoEncoder(
                    codec: codec,
                    pixelSize: plan.canvas,
                    frameRate: plan.frameRate
                )
                try await begin(engine: compositor, request: .mosaic(plan), encoder: encoder, source: source)
                pipelineLog.notice("mosaic source started with \(plan.tiles.count, privacy: .public) of \(layout.tiles.count, privacy: .public) tiles")
                return
            }

            let catalog = try await resolver.catalog()
            guard let descriptor = catalog.all.first(where: { $0.source == source }) else {
                throw CaptureError.sourceUnavailable("That capture source is no longer available.")
            }

            let plan = try resolver.makeFilter(for: source)
// One size, used twice, and it has to be the same expression both times. ScreenCaptureKit delivers a
// surface of exactly the configured size, and the encoder can encode nothing but a frame of its own,
// so a halved stream with a full-sized encoder is not a slightly wrong picture: it is the resize
// check below finding a different size on every frame and rebuilding the session sixty times a
// second.
            let pixelSize = resolution.pixelSize(for: descriptor.pixelSize)
            let configuration = try CaptureEngine.configuration(
                for: descriptor,
                pixelSize: pixelSize,
                frameRate: frameRate
            )
// Set after the configuration is built rather than inside it: the rectangle belongs to the filter,
// and `CaptureEngine` is handed only a descriptor. See ``CaptureFilterPlan``.
            if let sourceRect = plan.sourceRect {
                configuration.sourceRect = sourceRect
            }
// Pointer motion is rendered locally by the client, so it stays smooth on a quiet desktop without
// forcing ScreenCaptureKit to manufacture cursor-only frames.
            configuration.showsCursor = false
            let encoder = try VideoEncoder(codec: codec, pixelSize: pixelSize, frameRate: frameRate)

            try await begin(
                engine: engine,
                request: .stream(filter: plan.filter, configuration: configuration),
                encoder: encoder,
                source: source
            )
// The size is logged as well as the title, because the source's own size and half of it are
// otherwise indistinguishable from the log.
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
/// Shared by both backends, so neither can drift from the other's ordering. The callbacks are
/// attached before the source is started, or the first frames of a session have nowhere to go, and
/// the keyframe is asked for after it, because a request made before there is a session to make it on
/// is lost. A session's first frame must be a keyframe, since a client joining mid-stream has no
/// parameter sets and nothing to decode against.
    private func begin(
        engine: any CaptureFrameSource,
        request: CaptureStartRequest,
        encoder: VideoEncoder,
        source: CaptureSource
    ) async throws {
        attach(engine: engine, encoder: encoder, source: source)

        do {
            try await engine.start(request)
        } catch {
            await stop()
            throw error
        }

        encoder.requestKeyframe()
    }

/// Points the pipeline's callbacks at a source and an encoder, without starting anything.
///
/// Split out of ``begin(_:request:encoder:source:)`` so that a mosaic which is rearranged rather than
/// started goes through the same wiring: every one of these assignments can be got wrong in a way
/// that shows up as a picture that never arrives.
    private func attach(
        engine: any CaptureFrameSource,
        encoder: VideoEncoder,
        source: CaptureSource
    ) {
// Copyable because a `let` existential's settable properties cannot be assigned to, even when every
// conforming type is a class.
        var engine = engine

        lock.withLock {
            self.source = source
            self.encoder = encoder
            self.awaitsKeyframe = true
// Which of the capture pipeline's two sources this session is reading, so that the statistics, the
// stop and the input transform all answer about the one that is actually running.
            self.runningEngine = engine
        }
        encoder.onFrame = { [weak self] encoded in self?.deliver(encoded) }
        encoder.onFailure = { [weak self] error in self?.report(error) }

        engine.onFrame = { [weak self] frame in self?.ingest(frame) }
        engine.onIdle = { [weak self] sample in self?.idle(sample) }
        engine.onStop = { [weak self] error in self?.report(error) }
        if let captureEngine = engine as? CaptureEngine {
            captureEngine.enableAudio()
            captureEngine.onAudio = { [weak self] buffer in
                guard let self else { return }
                self.lock.withLock { self._onAudio }?(buffer)
            }
        }
        if let compositor = engine as? MosaicCompositor {
            compositor.onTileLost = { [weak self] _ in self?.noteSourceMayHaveGone() }
            compositor.onTileUncapturable = { [weak self] index in
                self?.noteTileUncapturable(index)
            }
        }
    }

    /// Something this session is capturing has gone. The phone's catalogue still lists it, so the
    /// only way it can be taken out of an arrangement is for the Mac to say so. See
    /// ``CaptureSourceResolver/invalidate()``.
    private func noteSourceMayHaveGone() {
        guard case .capture(let resolver, _, _) = backend else { return }
        resolver.invalidate()
    }

/// A tile that produced no picture at all, which is a fact about the source rather than about the
/// arrangement. Every other reason a tile is empty is a window that has closed or an application with
/// nothing open, and both of those are answered by the catalogue as it stands. Here the window is
/// open, listed, and will not render, so the only way the phone can stop offering it is for the
/// catalogue to stop listing it. See ``CaptureSourceResolver/markUncapturable(_:)``.
    private func noteTileUncapturable(_ index: Int) {
        guard case .capture(let resolver, _, let compositor) = backend,
              let source = compositor.source(forEngine: index)
        else { return }
        resolver.markUncapturable(source)
    }

/// Re-asks a running mosaic for a different arrangement of the same captures.
///
/// Says whether it could, rather than throwing, because every reason it cannot is a reason the
/// ordinary path handles properly: no mosaic running, a different set of windows, a catalogue that
/// has gone. Returning `false` sends the caller down ``stop()`` and the usual build.
///
/// The encoder is new either way: it is built for a canvas, and the canvas is what changed.
/// Everything else (the streams, their filters, the retained frames) belongs to the tiles rather than
/// to the canvas.
    private func recompose(_ source: CaptureSource) async -> Bool {
        guard case .mosaic(let requested) = source,
              let layout = requested.validated, !layout.tiles.isEmpty,
              case .capture(let resolver, _, let compositor) = backend
        else { return false }
// Running, or parked, and not merely existing: the captures to rearrange onto have to be the ones
// actually held. Parked counts, which is the whole of what a parked arrangement is for.
        let held = lock.withLock { (runningEngine as? MosaicCompositor, parkedMosaic) }
        guard held.0 === compositor || held.1 === compositor else { return false }

        guard let catalog = try? await resolver.catalog() else { return false }
        let plan = MosaicPlan.make(layout: layout, catalog: catalog, resolver: resolver)
        guard !plan.tiles.isEmpty, compositor.canReuseCaptures(for: plan) else { return false }

        guard let encoder = try? VideoEncoder(
            codec: codec,
            pixelSize: plan.canvas,
            frameRate: plan.frameRate
        ) else { return false }

// The engine that is not the arrangement goes before the canvas comes back. Coming home from one of
// its tiles, the window's stream is still running and still delivering to ``ingest``, and a canvas
// frame and a window frame alternating into one encoder is a rebuild per frame, because
// ``encode(_:)`` replaces the session every time a frame arrives at a size it was not built for.
        let departing = lock.withLock { runningEngine }
        if let departing, (departing as? MosaicCompositor) !== compositor {
            await departing.stop()
        }

        do {
            try await compositor.replan(plan)
        } catch {
            pipelineLog.error("""
                a mosaic could not be rearranged, so it is being rebuilt: \
                \(String(describing: error), privacy: .public)
                """)
            return false
        }

// Read before the attach, which replaces it, and shut down after: the same order
// ``rebuildEncoder(for:replacing:)`` keeps, so nothing can hand a frame to a dead session.
        let previousEncoder = lock.withLock { self.encoder }
        attach(engine: compositor, encoder: encoder, source: source)
        previousEncoder?.shutdown()
// Drawing again, so nothing is parked. See ``releaseRunningSource(keepingMosaicFor:)``.
        lock.withLock { parkedMosaic = nil }
        encoder.requestKeyframe()
        return true
    }

    func stop() async {
        await releaseRunningSource(keepingMosaicFor: nil)
    }

/// Stops what is running, keeping an arrangement's captures when the next source is one of its own
/// windows.
///
/// Leaving an arrangement for one of its tiles is the one switch that costs nothing: the captures are
/// what the second and a half was being spent on, and every one of them is about a window that is
/// still on the Mac and still in the arrangement. Parked, the way back is a composite of frames
/// already in hand rather than streams built again.
///
/// Anything else stops them. A source that is not one of the arrangement's windows is the user having
/// left it, and a parked arrangement kept past that would go on capturing windows nobody is looking
/// at for the rest of the process.
    private func releaseRunningSource(keepingMosaicFor next: CaptureSource?) async {
// Read before the stop, because it is what is being stopped: the engine that is not running must not
// be stopped in its place, and on a mosaic pipeline both exist.
        let running = lock.withLock { runningEngine } ?? engine
        var kept: MosaicCompositor?
        if let next, let compositor = running as? MosaicCompositor, compositor.holdsTile(next) {
            kept = compositor
            await compositor.park()
        } else {
            await running.stop()
        }

        let abandoned = lock.withLock { () -> MosaicCompositor? in
            let previous = parkedMosaic
            parkedMosaic = kept
            return previous === kept ? nil : previous
        }
        await abandoned?.stop()

        let encoder = lock.withLock { () -> VideoEncoder? in
            let current = self.encoder
            self.encoder = nil
            self.source = nil
            self.awaitsKeyframe = false
            self.runningEngine = nil
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

// The last point at which the frame is still this app's to draw on: after the encoder the buffer
// belongs to VideoToolbox, and this is also the only place that holds both the frame and the geometry
// saying where its content sits on screen, which is what placing a pointer takes.
//
// Not on a mosaic. A canvas is of no screen, so there is no rectangle for a pointer to be placed in,
// and nothing to place: each tile's stream has the real pointer drawn into it by ScreenCaptureKit, at
// that tile's own coordinates, which is where it actually is. See ``MosaicPlan``.
        if !isMosaic {
            overlay?.draw(into: frame.pixelBuffer, geometry: frame.geometry)
        }

        encode(frame)
    }

/// A sample that carried no new picture, on the capture queue.
///
/// Where the pointer's smoothness comes from. On a screen where nothing is happening the pointer is
/// the only thing that moves, and with `showsCursor` off nothing about it reaches the stream, so every
/// sample is idle and nothing is encoded. The overlay turns the pointer's own movement into a frame;
/// this is where it is asked.
///
/// An idle sample is otherwise worth nothing, being the picture the client already has, so when the
/// overlay cannot make anything of it the sample goes exactly where it went before: nowhere.
/// ``onGeometry`` is deliberately not told about these, because an idle sample's idea of where the
/// content sits can be emptier than a frame's, and letting a sparser answer overwrite a good one would
/// move the pointer and the taps apart.
    private func idle(_ sample: IdleSample) {
        guard Self.idleFramesEnabled else { return }
        guard let overlay, let frame = overlay.redraw(sample) else { return }
        encode(frame)
    }

/// Whether an idle sample is allowed to become a frame.
///
/// Off. It works in isolation, but on the device it does the opposite: with it on, the rate sits
/// around thirty until the pointer is touched and then collapses, which is the signature of the client
/// refusing what this path invents. The first synthetic frame fails to decode, the renderer resets and
/// latches onto awaiting-a-keyframe, and from then on the only pictures that get through are the
/// keyframes. Whatever is wrong is in what these frames are rather than in the idea, and that is a
/// diagnosis to make against a running system.
    private static let idleFramesEnabled = false

/// Hands a frame of this pipeline's own making to the encoder.
///
/// Shared with the idle path rather than letting that path reach the encoder directly, which keeps
/// the two from drifting: a frame the overlay drew a pointer into and a frame it built out of an idle
/// sample are the same thing from here on, both going through the resize check and the keyframe
/// bookkeeping.
    private func encode(_ frame: CapturedFrame) {
// The stream's surface changes size when a captured window is resized: the stream keeps producing
// frames at the new size, but the session was created for the old one and cannot encode a frame of a
// different size at all. Rebuilding is the only option, and it costs the client a keyframe, so it
// happens on the size changing rather than on every frame.
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
/// Built for the size the surface is now, never for the size the stream was configured with. At half
/// resolution those two differ for a captured window: the stream is configured at half the window's
/// size, and a window grown past that produces a surface of its own size again. The replacement keeps
/// up with the frames rather than with the setting, so the halving comes back with the next capture.
    private func rebuildEncoder(for size: CGSize, replacing current: VideoEncoder?) throws -> VideoEncoder {
        let replacement = try VideoEncoder(
            codec: codec,
            pixelSize: size,
            frameRate: current?.frameRate ?? 60
        )
        replacement.onFrame = { [weak self] encoded in self?.deliver(encoded) }
        replacement.onFailure = { [weak self] error in self?.report(error) }

// A new session has no keyframe that a decoder following the old one can use, so one is owed whether
// or not the session asked for it.
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
/// A stream that stopped is not torn down here. The session decides: sleeping and waking should
/// restart the stream, while a revoked permission should put an explanation on screen, and only the
/// session knows which one it is looking at.
    private func report(_ error: CaptureError) {
        let failure = lock.withLock { _onFailure }
        failure?(error)
    }
}
