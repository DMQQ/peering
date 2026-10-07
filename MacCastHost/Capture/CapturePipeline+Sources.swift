import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

extension CapturePipeline {
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
    func noteSourceMayHaveGone() {
        guard case .capture(let resolver, _, _) = backend else { return }
        resolver.invalidate()
    }

    /// A source this pipeline built a stream for and got nothing out of; otherwise taps on it do nothing. See ``CaptureSourceResolver/markUncapturable(_:)``.
    func markUncapturable(_ source: CaptureSource) {
        guard case .capture(let resolver, _, _) = backend else { return }
        resolver.markUncapturable(source)
    }

    /// A tile that produced no picture although its window is open and listed. See ``CaptureSourceResolver/markUncapturable(_:)``.
    func noteTileUncapturable(_ index: Int) {
        guard case .capture(let resolver, _, let compositor) = backend,
              let source = compositor.source(forEngine: index)
        else { return }
        resolver.markUncapturable(source)
    }

    /// Re-arranges a running mosaic's captures. Returns false rather than throwing when it cannot, sending the caller down ``stop()`` and the usual build. The encoder is always new, for the new canvas.
    func recompose(_ source: CaptureSource) async -> Bool {
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
    func releaseRunningSource(keepingMosaicFor next: CaptureSource?) async {
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
}
