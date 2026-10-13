import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import PeeringKit
import RemoteCore
import ScreenCaptureKit
import os

extension MosaicCompositor {
/// The same sources at the same frame rate, in any order: captures are the expensive part and the canvas owns where they are drawn. A tile surface size is not part of it, since replan(_:) re-points a stream rather than replacing it.
    func canReuseCaptures(for plan: MosaicPlan) -> Bool {
        let (current, engines) = lock.withLock { (self.plan, self.engines) }
        guard let current,
              engines.count == plan.tiles.count,
              current.frameRate == plan.frameRate,
              current.tiles.count == plan.tiles.count
        else { return false }
        return Set(current.tiles.map(\.source)) == Set(plan.tiles.map(\.source))
    }

/// A tile whose shape changed is re-pointed, not restarted (ScreenCaptureKit changes a stream shape in place); one that will not take the new shape keeps the old, since stopping would leave it black until everything is rebuilt.
    func replan(_ plan: MosaicPlan) async throws {
        let pool = try Self.makePool(for: plan.canvas)
        let (current, engines, previous) = lock.withLock {
            (self.plan, self.engines, self.engineForSlot)
        }

// Each engine is found by source, not slot, through the previous arrangement and its mapping: counting slots gives the same answer after one rearrangement and a different one after two. See MosaicRearrangement. The guard is unreachable through canReuseCaptures(for:).
        guard let current, current.tiles.count == plan.tiles.count,
              let engineForSlot = MosaicRearrangement.engineOrder(
                  previous: previous,
                  sources: current.tiles.map(\.source.stableID),
                  slots: plan.tiles.map(\.source.stableID)
              ),
              engineForSlot.allSatisfy({ $0 < engines.count })
        else {
            throw CaptureError.streamFailed(
                "This rearrangement is not the same windows as the mosaic that is running."
            )
        }

// Together, as with starting: a phone turn reshapes every tile at once. The configuration is built inside the task from the plan because SCStreamConfiguration is not Sendable.
        let reshaping: [(index: Int, engine: CaptureEngine)] = plan.tiles.enumerated().compactMap { index, tile in
            guard let was = current.tiles.firstIndex(where: { $0.source == tile.source }) else {
                return nil
            }
            let old = current.tiles[was]
            guard old.pixelSize != tile.pixelSize || current.frameRate != plan.frameRate else {
                return nil
            }
            return (index, engines[engineForSlot[index]])
        }

        await withTaskGroup(of: (index: Int, error: Error?).self) { group in
            for reshape in reshaping {
                group.addTask {
                    do {
                        try await reshape.engine.reconfigure(plan.tiles[reshape.index].configuration)
                        return (reshape.index, nil)
                    } catch {
                        return (reshape.index, error)
                    }
                }
            }
            for await (index, error) in group {
                guard let error else { continue }
                mosaicLog.error("""
                    mosaic tile \(index, privacy: .public) kept its old shape: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }

        let wasParked = lock.withLock { () -> Bool in
// The frames are not moved: they are held by engine, which stays the same engine; only the slot changes. Permuting held frames instead leaves callbacks indexed by engine overwriting each tile with another window's picture.
            self.engineForSlot = engineForSlot
            self.plan = plan
            self.pool = pool
// New canvas and encoder, so the timeline restarts; a running counter would put the first frame at an unexpected timestamp.
            self.frameIndex = 0
            self.dirty = true
            let parked = self.isParked
            self.isParked = false
            return parked
        }

// A parked arrangement returns on the next tick: every tile that can deliver already has. The bound is armed anyway, for a tile that died while parked.
        if wasParked {
            lock.withLock {
                self.firstCanvasAt = DispatchTime.now()
                self.firstCanvasDeadline = DispatchTime.now() + .milliseconds(700)
                self.firstCanvasSent = false
            }
            startTimer(plan)
        }

        mosaicLog.notice("""
            mosaic rearranged: \(plan.tiles.count, privacy: .public) tiles on a \
            \(Int(plan.canvas.width), privacy: .public)×\(Int(plan.canvas.height), privacy: .public) canvas
            """)
    }
}
