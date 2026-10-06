import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

private let pipelineLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Capture and encode as one unit the session drives, owning the rules that tie them together: a resize past the encoder's size rebuilds it, and a rebuilt encoder owes a keyframe.
/// Runs on the serial capture queue, which is what makes the encoder swap safe without a lock.
final class CapturePipeline: @unchecked Sendable {
    /// Two cases rather than an optional resolver: the synthetic path must be unable to reach ScreenCaptureKit, which fails or kills the process without Screen Recording.
    private enum Backend {
        /// A mosaic is a capture source like any other, selected with the same command; selecting one of its tiles is an ordinary source switch.
        case capture(resolver: CaptureSourceResolver, engine: CaptureEngine, compositor: MosaicCompositor)
        case synthetic(engine: SyntheticCaptureEngine)
    }

    private let backend: Backend
    private let codec: VideoCodec
    /// Nil on synthetic pipelines (no screen) and for callers with no preferences store. See ``CursorOverlay``.
    private let overlay: CursorOverlay?
    private let lock = NSLock()

    private var encoder: VideoEncoder?
    private var source: CaptureSource?
    /// Held here, not only in the encoder: the encoder can be replaced mid-flight, and a request that dies with the old session leaves the client on a picture that never resolves.
    private var awaitsKeyframe = false

    private var _onFrame: (@Sendable (EncodedFrame, CaptureSource) -> Void)?
    private var _onGeometry: (@Sendable (FrameGeometry) -> Void)?
    private var _onFailure: (@Sendable (CaptureError) -> Void)?
    private var _onAudio: (@Sendable (CMSampleBuffer) -> Void)?

    var onFrame: (@Sendable (EncodedFrame, CaptureSource) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    var onAudio: (@Sendable (CMSampleBuffer) -> Void)? {
        get { lock.withLock { _onAudio } }
        set { lock.withLock { _onAudio = newValue } }
    }

    /// A dragged or resized window changes this with no notification, so it is the only way input mapping stays correct for anything but a display.
    var onGeometry: (@Sendable (FrameGeometry) -> Void)? {
        get { lock.withLock { _onGeometry } }
        set { lock.withLock { _onGeometry = newValue } }
    }

    var onFailure: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onFailure } }
        set { lock.withLock { _onFailure = newValue } }
    }

    /// Which of the engine and the compositor the last ``start(source:frameRate:resolution:)`` selected. Nil while stopped.
    private var runningEngine: (any CaptureFrameSource)?

    /// Read from the recorded source rather than the engine, to avoid a lock on the frame path.
    private var isMosaic: Bool { lock.withLock { source }?.isMosaic ?? false }

    /// The arrangement whose captures keep running behind a window on screen. Cannot be derived from ``runningEngine``. See ``releaseRunningSource(keepingMosaicFor:)``.
    private var parkedMosaic: MosaicCompositor?

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

    /// Generates its own frames so the real pipeline runs where Screen Recording is not granted. Nothing here touches ScreenCaptureKit; the source passed to `start` is only recorded.
    init(syntheticPixelSize: CGSize, frameRate: Int = 60, codec: VideoCodec = .h264) {
        self.backend = .synthetic(
            engine: SyntheticCaptureEngine(pixelSize: syntheticPixelSize, frameRate: frameRate)
        )
        self.codec = codec
        self.overlay = nil
    }

    var currentSource: CaptureSource? {
        lock.withLock { source }
    }

    struct Statistics: Sendable, Equatable {
        /// Frames the stream delivered with a picture. Not what the client received: the overlay turns idle samples into frames, so read it alongside `framesEncoded`.
        let framesDelivered: Int
        /// Samples with no new picture. Not frame loss: each is a chance for a pointer frame.
        let idleSamples: Int
        let framesEncoded: Int
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

    /// Built from catalogue-time geometry; prefer ``onGeometry`` for windows, whose content moves unannounced. Synthetic pipelines answer ``InputTransform/degenerate``. Nil while stopped.
    func inputTransform() -> InputTransform? {
        switch backend {
        case .capture(let resolver, _, _):
            // A mosaic answers ``InputTransform/degenerate``: a tap's tile decides the machine coordinate, and the host refuses input while a mosaic is up. With a tile selected, that tile's transform.
            return lock.withLock { source }.map { resolver.inputTransform(for: $0) }
        case .synthetic:
            return lock.withLock { source }.map { _ in .degenerate }
        }
    }

    /// Detached: the result arrives later on the catalogue push. Does nothing when synthetic.
    func refreshSpacePreviews() {
        guard case .capture(let resolver, _, _) = backend else { return }
        Task { await resolver.refreshSpacePreviews() }
    }

    func refreshSourceThumbnails() {
        guard case .capture(let resolver, _, _) = backend else { return }
        Task { await resolver.refreshSourceThumbnails() }
    }

    private var thumbnailWatch: Task<Void, Never>?

    /// Keeps the picker's thumbnails current while it is open, one pass at a time, so many windows never stack captures on the live stream.
    func watchSourceThumbnails(_ watching: Bool) {
        guard case .capture(let resolver, _, _) = backend else { return }
        lock.withLock {
            thumbnailWatch?.cancel()
            thumbnailWatch = nil
            guard watching else { return }
            thumbnailWatch = Task {
                await resolver.refreshSourceThumbnails()
                var pass = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    pass += 1
                    await resolver.refreshChangedSourceThumbnails(reenumerate: pass % 5 == 0)
                    await resolver.refreshChangedSpacePreviews()
                }
            }
        }
    }

    /// A still of what is streaming, or nil. Kept off the stream's own frames so the host window's refresh stays off the capture queue. Nil when synthetic.
    func snapshot(maxWidth: Int) async -> CGImage? {
        guard case .capture(let resolver, _, _) = backend,
              let source = lock.withLock({ source }),
              // A canvas cannot be photographed; show nothing rather than one window posing as the mosaic.
              !source.isMosaic
        else { return nil }
        return await resolver.snapshot(of: source, maxWidth: maxWidth)
    }

    /// Empty when synthetic.
    func catalog() async throws -> CaptureCatalog {
        switch backend {
        // Not filtered while a mosaic is up: the client picking a tile reads this list, and an emptied picker would defeat it.
        case .capture(let resolver, _, _): return try await resolver.catalog()
        case .synthetic: return CaptureCatalog()
        }
    }

    // MARK: - Lifecycle

    /// Re-reads the catalogue first, since the client's list may be seconds stale; failing here names the missing source.
    /// A synthetic pipeline takes the source as given, ignores frame rate and resolution, and cannot fail.
    func start(
        source: CaptureSource,
        frameRate: Int = 60,
        resolution: CaptureResolution = .full
    ) async throws {
        // Before the stop: re-composing the same windows in new rectangles must keep the captures (stopping first cost a second and a half of black). See ``recompose(_:)``.
        if await recompose(source) { return }

        await releaseRunningSource(keepingMosaicFor: source)

        switch backend {
        case .capture(let resolver, let engine, let compositor):
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
                // Canvas rate, not ``CaptureResolution``: the client chose the canvas size, so the resolution setting does nothing while a mosaic is up.
                let encoder = try VideoEncoder(
                    codec: codec,
                    pixelSize: plan.canvas,
                    frameRate: plan.frameRate
                )
                try await begin(engine: compositor, request: .mosaic(plan), encoder: encoder, source: source)
                pipelineLog.notice("mosaic source started with \(plan.tiles.count, privacy: .public) of \(layout.tiles.count, privacy: .public) tiles")
                return
            }

            await resolver.bringOnScreen(source)
            let catalog = try await resolver.catalog()
            guard let descriptor = catalog.all.first(where: { $0.source == source }) else {
                throw CaptureError.sourceUnavailable("That capture source is no longer available.")
            }

            let plan = try resolver.makeFilter(for: source)
            // Stream and encoder must use the same size expression: a halved stream with a full-size encoder rebuilds the session every frame.
            let pixelSize = resolution.pixelSize(for: descriptor.pixelSize)
            let configuration = try CaptureEngine.configuration(
                for: descriptor,
                pixelSize: pixelSize,
                frameRate: frameRate
            )
            // Set after the configuration is built: the rectangle belongs to the filter. See ``CaptureFilterPlan``.
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

    /// Shared by both backends. Callbacks attach before the source starts; the keyframe is requested after, since a request with no session is lost. The first frame must be a keyframe.
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

    /// The callback wiring alone, shared with mosaic re-arrangement.
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
            self.runningEngine = engine
        }
        encoder.onFrame = { [weak self] encoded in self?.deliver(encoded, source: source) }
        encoder.onFailure = { [weak self] error in self?.report(error) }

        engine.onFrame = { [weak self] frame in self?.ingest(frame, source: source) }
        engine.onIdle = { [weak self] sample in self?.idle(sample, source: source) }
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

    /// Forgets the window list if a window moved, so the next lookup is current.
    func forgetWindowListIfStale() {
        guard case .capture(let resolver, _, _) = backend else { return }
        resolver.invalidateIfWindowsMoved()
    }

    func forgetWindowList() {
        guard case .capture(let resolver, _, _) = backend else { return }
        resolver.invalidate()
    }

    /// A captured source has gone while the phone's catalogue still lists it. See ``CaptureSourceResolver/invalidate()``.
    private func noteSourceMayHaveGone() {
        guard case .capture(let resolver, _, _) = backend else { return }
        resolver.invalidate()
    }

    /// A source this pipeline built a stream for and got nothing out of; otherwise taps on it do nothing. See ``CaptureSourceResolver/markUncapturable(_:)``.
    func markUncapturable(_ source: CaptureSource) {
        guard case .capture(let resolver, _, _) = backend else { return }
        resolver.markUncapturable(source)
    }

    /// A tile that produced no picture although its window is open and listed. See ``CaptureSourceResolver/markUncapturable(_:)``.
    private func noteTileUncapturable(_ index: Int) {
        guard case .capture(let resolver, _, let compositor) = backend,
              let source = compositor.source(forEngine: index)
        else { return }
        resolver.markUncapturable(source)
    }

    /// Re-arranges a running mosaic's captures. Returns false rather than throwing when it cannot, sending the caller down ``stop()`` and the usual build. The encoder is always new, for the new canvas.
    private func recompose(_ source: CaptureSource) async -> Bool {
        guard case .mosaic(let requested) = source,
              let layout = requested.validated, !layout.tiles.isEmpty,
              case .capture(let resolver, _, let compositor) = backend
        else { return false }
        // Parked counts: the held captures are what gets rearranged.
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

        // The window's engine stops before the canvas returns: alternating canvas and window frames into one encoder rebuilds it every frame.
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

        // Read before the attach and shut down after, so nothing hands a frame to a dead session.
        let previousEncoder = lock.withLock { self.encoder }
        attach(engine: compositor, encoder: encoder, source: source)
        previousEncoder?.shutdown()
        lock.withLock { parkedMosaic = nil }
        encoder.requestKeyframe()
        return true
    }

    func stop() async {
        await releaseRunningSource(keepingMosaicFor: nil)
    }

    /// Keeps (parks) an arrangement's captures when the next source is one of its windows. Anything else stops them, or they would capture for the rest of the process.
    private func releaseRunningSource(keepingMosaicFor next: CaptureSource?) async {
        // Read before the stop: the engine that is not running must not be stopped in its place.
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

    /// Forces the next frame to be a keyframe without waiting for the interval or tearing the session down.
    func requestKeyframe() {
        let encoder = lock.withLock { () -> VideoEncoder? in
            awaitsKeyframe = true
            return self.encoder
        }
        encoder?.requestKeyframe()
    }

    /// Also arms a keyframe so the new rate applies quickly.
    func setBitrate(_ bitsPerSecond: Int) {
        let encoder = lock.withLock { self.encoder }
        encoder?.setBitrate(bitsPerSecond)
        encoder?.requestKeyframe()
    }

    // MARK: - Frame flow

    private func ingest(_ frame: CapturedFrame, source: CaptureSource) {
        guard lock.withLock({ self.source == source }) else { return }
        onGeometry?(frame.geometry)

        // The last point where the frame is still ours to draw on, and the only one holding both frame and geometry. Not on a mosaic: each tile's stream already has the real pointer drawn in by ScreenCaptureKit. See ``MosaicPlan``.
        if !isMosaic {
            overlay?.draw(into: frame.pixelBuffer, geometry: frame.geometry)
        }

        encode(frame, source: source)
    }

    /// Where pointer smoothness on a still screen comes from: the overlay turns pointer movement into a frame.
    /// ``onGeometry`` is not told about idle samples: their geometry can be emptier than a frame's and would overwrite a good one.
    private func idle(_ sample: IdleSample, source: CaptureSource) {
        guard lock.withLock({ self.source == source }) else { return }
        guard Self.idleFramesEnabled else { return }
        guard let overlay, let frame = overlay.redraw(sample) else { return }
        encode(frame, source: source)
    }

    /// Off: on the device the rate collapses once the pointer is touched, because the first synthetic frame fails to decode and the renderer latches awaiting a keyframe. The fault is in what these frames are.
    private static let idleFramesEnabled = false

    /// Shared with the idle path so both go through the resize check and keyframe bookkeeping.
    private func encode(_ frame: CapturedFrame, source: CaptureSource) {
        // A resized window yields frames the old session cannot encode; rebuild on a size change only.
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
                encoder = try rebuildEncoder(for: size, replacing: current, source: source)
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

    /// Capture queue only. Built for the surface's current size, not the configured one: at half resolution a grown window produces a full-size surface.
    private func rebuildEncoder(
        for size: CGSize,
        replacing current: VideoEncoder?,
        source: CaptureSource
    ) throws -> VideoEncoder {
        let replacement = try VideoEncoder(
            codec: codec,
            pixelSize: size,
            frameRate: current?.frameRate ?? 60
        )
        replacement.onFrame = { [weak self] encoded in self?.deliver(encoded, source: source) }
        replacement.onFailure = { [weak self] error in self?.report(error) }

        // A new session owes a keyframe whether or not one was asked for.
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

    private func deliver(_ encoded: EncodedFrame, source: CaptureSource) {
        guard lock.withLock({ self.source == source }) else { return }
        if encoded.isKeyframe {
            lock.withLock { awaitsKeyframe = false }
        }
        let consumer = lock.withLock { _onFrame }
        consumer?(encoded, source)
    }

    /// The session decides what a stop means: wake restarts the stream, a revoked permission shows an explanation.
    private func report(_ error: CaptureError) {
        let failure = lock.withLock { _onFailure }
        failure?(error)
    }
}
