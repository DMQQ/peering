import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MacCastKit
import RemoteCore
import ScreenCaptureKit
import os

extension MosaicCompositor {
    func start(_ request: CaptureStartRequest) async throws {
        guard case .mosaic(let plan) = request else {
// Unreachable: the pipeline builds the plan it passes. Stated rather than crashed.
            throw CaptureError.streamFailed("The mosaic compositor was started with something that is not a mosaic.")
        }

        let pool = try Self.makePool(for: plan.canvas)

// A timer from a start never stopped: cancelled here, since a resumed source nothing holds goes on firing at a plan this object no longer has.
        let stale = lock.withLock { () -> DispatchSourceTimer? in
            let current = self.timer
            self.timer = nil
            return current
        }
        stale?.cancel()

        let generation = lock.withLock { () -> Int in
            self.generation += 1
            self.plan = plan
            self.pool = pool
            self.held = Array(repeating: nil, count: plan.tiles.count)
// Identity: engine i was built for tile i of the arrangement being started. See engineForSlot.
            self.engineForSlot = MosaicRearrangement.identity(count: plan.tiles.count)
            self.dirty = false
            self.frameIndex = 0
            self.deliveredCount = 0
            self.skippedTicks = 0
            self.deadTiles = []
            self.emptyTiles = []
            self.isParked = false
            return self.generation
        }

// Each engine delivers on its own queue, so arrival order between tiles means nothing; hence the tick.
        let engines: [CaptureEngine] = plan.tiles.indices.map { index in
            let engine = CaptureEngine()
            engine.onFrame = { [weak self] frame in
                self?.retain(frame.pixelBuffer, geometry: frame.geometry, at: index)
            }
            engine.onStop = { [weak self] _ in
                self?.tileStopped(index)
            }
            return engine
        }

// Published before they start so a stop can reach them: held back, a stop mid-loop cleared an empty array and the tiles came up with nothing holding them. See generation.
        lock.withLock {
            guard self.generation == generation else { return }
            self.engines = engines
// A tile whose stream never delivers must not hold the whole picture: the six streams start over about a third of a second and each delivers soon after, so what is left past this deadline never will, and tick() stops waiting for it.
            self.firstCanvasAt = DispatchTime.now()
            self.firstCanvasDeadline = DispatchTime.now() + .milliseconds(700)
            self.firstCanvasSent = false
        }

// The timer before the streams: a tick with no picture is a no-op, and starting it first shows the mosaic when the first window is up rather than the slowest of six (a few hundred ms each).
        startTimer(plan)

// One at a time: concurrent startCapture() calls can interrupt the capture service, refusing one and stopping every stream with application connection being interrupted.
        for (index, tile) in plan.tiles.enumerated() {
            guard isCurrent(generation) else { break }
            do {
                try await engines[index].start(
                    .stream(filter: tile.filter, configuration: tile.configuration)
                )
            } catch {
                CaptureHostHooks.reportFailure(error)
                let failure = CaptureError.from(error)
                mosaicLog.error("mosaic tile \(index, privacy: .public) did not start: \(String(describing: failure), privacy: .public)")
                if isCurrent(generation) { markDead(index) }
            }
        }

        mosaicLog.notice("mosaic started: \(plan.tiles.count, privacy: .public) tiles, \(plan.placeholders.count, privacy: .public) empty, at \(Int(plan.canvas.width), privacy: .public)×\(Int(plan.canvas.height), privacy: .public)")
    }

/// Asked wherever a start could publish state a stop has given up on. See generation.
    private func isCurrent(_ generation: Int) -> Bool {
        lock.withLock { self.generation == generation }
    }

    func stop() async {
// The timer first so no tick is in flight during teardown. Cancelling a running handler waits on this queue, hence the drain.
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            let current = self.timer
            self.timer = nil
            return current
        }
        timer?.cancel()
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            queue.sync {}
        }

// Before taking the engines, so a start in flight sees it at the same moment: taking them and bumping the generation are one decision.
        let engines = lock.withLock { () -> [CaptureEngine] in
            self.generation += 1
            let current = self.engines
            self.engines = []
            self.engineForSlot = []
            return current
        }
// Together: this is on the critical path of every source switch, and one at a time is the teardown multiplied by the window count. Frames arriving meanwhile are dropped by a compositor with no plan.
        await withTaskGroup(of: Void.self) { group in
            for engine in engines {
                group.addTask { await engine.stop() }
            }
        }

        lock.withLock {
            self.plan = nil
            self.pool = nil
            self.held = []
            self.dirty = false
            self.deadTiles = []
            self.emptyTiles = []
            self.isParked = false
        }
    }

/// Unlike onTileLost: this tile has produced nothing at all and this Mac cannot capture it, so the catalogue must answer. An empty content rectangle is a running stream of an open but empty window. See CaptureSourceResolver/markUncapturable(_:).
    var onTileUncapturable: (@Sendable (Int) -> Void)? {
        get { lock.withLock { _onTileUncapturable } }
        set { lock.withLock { _onTileUncapturable = newValue } }
    }

/// Callbacks are indexed by engine, and the arrangement matches build order only until the first rearrangement. See engineForSlot.
    func source(forEngine index: Int) -> CaptureSource? {
        lock.withLock {
            guard let plan,
                  let slot = engineForSlot.firstIndex(of: index),
                  plan.tiles.indices.contains(slot)
            else { return nil }
            return plan.tiles[slot].source
        }
    }

    func holdsTile(_ source: CaptureSource) -> Bool {
        lock.withLock { plan?.tiles.contains { $0.source == source } ?? false }
    }

/// Stops drawing canvases and keeps every capture, so returning to the arrangement from one of its windows is one composite rather than six streams. Only the timer stops. A caller parks only for one of its own tiles; anything else reaches stop().
    func park() async {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            let current = self.timer
            self.timer = nil
            self.isParked = true
            return current
        }
        timer?.cancel()
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            queue.sync {}
        }
        mosaicLog.notice("mosaic parked: \(self.liveTileCount, privacy: .public) captures kept")
    }
}
