import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

extension CapturePipeline {
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
    func begin(
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
    func attach(
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
}
