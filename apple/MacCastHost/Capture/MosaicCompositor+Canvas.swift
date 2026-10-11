import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MacCastKit
import RemoteCore
import ScreenCaptureKit
import os

extension MosaicCompositor {
/// Copied because the frame buffer belongs to a pool ScreenCaptureKit reuses once the callback returns, so keeping the reference would read memory that has become something else. Geometry comes along to answer whether the picture holds anything (see emptyTiles). index is the engine's, stable for the tile's life.
    func retain(_ buffer: CVPixelBuffer, geometry: FrameGeometry?, at index: Int) {
        guard let copy = Self.copy(buffer) else { return }
// An empty content rectangle means nothing here (an application whose last window closed). No geometry at all means nobody said and leaves the tile as it was, rather than inventing a fault.
        let empty = geometry?.contentRect?.isEmpty ?? false

        let (lost, callback) = lock.withLock {
            () -> (Bool, (@Sendable (Int) -> Void)?) in
            guard index < held.count else { return (false, nil) }
            held[index] = HeldFrame(buffer: copy)
            dirty = true
// A delivering tile is not dead whatever a past deadline decided: a window not rendered at build can start rendering, and its card would otherwise stay over a live picture.
            deadTiles.remove(index)
            guard empty else {
                emptyTiles.remove(index)
                return (false, nil)
            }
            // Only the first empty frame is news; every frame after it says the same thing.
            return (emptyTiles.insert(index).inserted, _onTileLost)
        }
        if lost { callback?(index) }
    }

    func markDead(_ index: Int) {
        let (first, callback) = lock.withLock {
            (deadTiles.insert(index).inserted, _onTileLost)
        }
        if first { callback?(index) }
    }

    func tileStopped(_ index: Int) {
        markDead(index)
// A stream that started then stopped is the same evidence as one that never delivered. See onTileUncapturable.
        lock.withLock { _onTileUncapturable }?(index)
        let (dead, total, callback) = lock.withLock { (deadTiles, engines.count, _onStop) }
        guard total > 0, dead.count >= total else { return }
        callback?(.streamStopped(code: 0, description: "Every window in this mosaic has stopped being captured."))
    }

    func startTimer(_ plan: MosaicPlan) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(max(plan.frameRate, 1))
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

/// Every tick draws, changed or not: a keyframe request from a new client must be answered with a frame, and identical frames cost the encoder a small delta.
    private func tick() {
        let (plan, pool) = lock.withLock { (self.plan, self.pool) }
        guard let plan, let pool, !plan.tiles.isEmpty else { return }

// Nothing yet: a black canvas would be an invented failure the client cannot tell from a sleeping Mac. The first canvas waits for every tile, not the first, or it arrives with the others black, which the phone cannot tell from black windows. Bounded by the deadline: a tile that starts and says nothing must not hold the picture.
        let (started, settled, waited, ready, expired) = lock.withLock {
            () -> (Bool, Bool, Double, Int, [Int]) in
            guard held.contains(where: { $0 != nil }) else { return (false, false, 0, 0, []) }
            let live = held.filter { $0 != nil }.count
            let outstanding = held.indices.filter { held[$0] == nil && !deadTiles.contains($0) }
            let elapsed = firstCanvasAt.map {
                Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000
            } ?? 0
            guard !outstanding.isEmpty else { return (true, true, elapsed, live, []) }
            guard let deadline = firstCanvasDeadline, DispatchTime.now() >= deadline else {
                return (true, false, elapsed, live, [])
            }
            return (true, true, elapsed, live, outstanding)
        }

// Past the deadline a never-delivered tile is never going to: a hidden, minimised or off-Space window starts a stream and says nothing. Marked dead it draws a card, stops the canvas waiting, and tells the phone.
        for index in expired { markDead(index) }
// Reported as the stronger fact, after the loop above so the catalogue invalidation from a lost tile cannot arrive first and take the report with it.
        for index in expired { lock.withLock { _onTileUncapturable }?(index) }
        guard started, settled else { return }

// Said out loud: an empty canvas and a late canvas are the same complaint from the phone and want opposite fixes.
        if !firstCanvasSent {
            firstCanvasSent = true
            mosaicLog.notice("""
                first canvas: \(ready, privacy: .public) of \(self.held.count, privacy: .public) tiles \
                live after \(Int(waited), privacy: .public)ms, \(settled ? "all ready" : "deadline")
                """)
        }

        var canvasBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &canvasBuffer)
        guard status == kCVReturnSuccess, let canvasBuffer else {
// Back-pressure, not an error: the tick is dropped and the next draws the same tiles.
            lock.withLock { skippedTicks += 1 }
            return
        }

        draw(plan: plan, into: canvasBuffer)

        lock.withLock {
            frameIndex += 1
            deliveredCount += 1
            dirty = false
        }

        let rate = CMTimeScale(max(plan.frameRate, 1))
        let time = CMTime(value: frameIndex, timescale: rate)
        let frame = CapturedFrame(
            pixelBuffer: canvasBuffer,
            presentationTime: time,
            duration: CMTime(value: 1, timescale: rate),
// A canvas is of no screen; reports nothing per frame, like a display. See CaptureSource/contentMovesOnItsOwn.
            geometry: FrameGeometry(contentRect: nil, contentScale: nil, scaleFactor: nil, screenRect: nil)
        )
        lock.withLock { _onFrame }?(frame)
    }

/// A tile with no picture gets a card instead of a hole: no capture could be built (MosaicPlan/Placeholder), the stream ended, or its content rectangle says nothing to show (emptyTiles). An ended stream loses its last picture to the card, since that was a photograph of a window that no longer exists.
    private func draw(plan: MosaicPlan, into canvas: CVPixelBuffer) {
        let bounds = CGRect(origin: .zero, size: plan.canvas)
        let (frames, empty, dead, mapping) = lock.withLock {
            (held, emptyTiles, deadTiles, engineForSlot)
        }

        var image = CIImage(color: .black).cropped(to: bounds)
        for (index, tile) in plan.tiles.enumerated() {
// Two index spaces meet here: the loop is over the client's slots, while the picture, dead flag and empty flag belong to an engine. See engineForSlot.
            guard index < mapping.count else { continue }
            let engine = mapping[index]

            if empty.contains(engine) || dead.contains(engine),
               let card = tile.card.picture.map({ Self.place($0, in: tile.rect, canvas: plan.canvas) }) {
                image = card.composited(over: image)
                continue
            }
// Nothing yet: not a card, since a tile slow to start is a mosaic still coming up.
            guard engine < frames.count, let frame = frames[engine] else { continue }
            let picture = CIImage(cvPixelBuffer: frame.buffer)
            image = Self.place(picture, in: tile.rect, canvas: plan.canvas).composited(over: image)
        }

        for placeholder in plan.placeholders {
            guard let card = placeholder.card else { continue }
            image = Self.place(card, in: placeholder.rect, canvas: plan.canvas).composited(over: image)
        }

        context.render(
            image,
            to: canvas,
            bounds: bounds,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
    }

/// Letterboxed, not stretched, so each window keeps its aspect ratio. The vertical flip is here only: tile rectangles are top-left (the client's space) and CoreImage is bottom-left.
/// Internal for the probe: a wrong flip puts the first tile bottom-left, indistinguishable from a Mac showing something upside down. See Tools/CaptureProbe --compose-check.
    static func place(_ image: CIImage, in rect: CGRect, canvas: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, rect.width > 0, rect.height > 0 else { return image }

        let scale = min(rect.width / extent.width, rect.height / extent.height)
        let width = extent.width * scale
        let height = extent.height * scale
        let x = rect.minX + (rect.width - width) / 2
        let y = canvas.height - rect.maxY + (rect.height - height) / 2

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}
