import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MacCastKit
import RemoteCore
import ScreenCaptureKit
import os

private let mosaicLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A tile whose source has gone is left out of tiles rather than failing the plan: five pictures and a black rectangle beats a mosaic that never appears.
struct MosaicPlan: @unchecked Sendable {
    struct Tile: @unchecked Sendable {
        let source: CaptureSource
        let rect: CGRect
/// The tile's pixels in the canvas, never more than the source's own: the mosaic's cost control, since ScreenCaptureKit scales down for us.
        let pixelSize: CGSize
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
/// Drawn on first use when the tile has no picture: a stream that will not start or stopped before any frame. See MosaicPlaceholder/Card.
        let card: MosaicPlaceholder.Card
    }

/// Kept out of tiles because everything there assumes a capture: an engine, a held frame and a dead-set index each.
    struct Placeholder: @unchecked Sendable {
        let rect: CGRect
        let card: CIImage?
    }

    let canvas: CGSize
    let frameRate: Int
    let tiles: [Tile]
    let placeholders: [Placeholder]
}

extension MosaicPlan {
/// A tile whose source has gone stays on the canvas as a card: a window closed between the phone drawing the arrangement and the Mac building it is the ordinary start, not an error. Every tile gone is a mosaic with nothing in it, and the caller says so.
    static func make(
        layout: MosaicLayout,
        catalog: CaptureCatalog,
        resolver: CaptureSourceResolver
    ) -> MosaicPlan {
        var tiles: [Tile] = []
        var placeholders: [Placeholder] = []

        for tile in layout.tiles {
            let rect = tile.rect.pixels(in: layout.canvas)
            let descriptor = catalog.descriptor(for: tile.source)

            guard let descriptor,
                  let filterPlan = try? resolver.makeFilter(for: tile.source)
            else {
// In the arrangement but not the catalogue: nothing to capture. The card is built regardless, since the process table still knows the name and icon of an application with nothing open.
                placeholders.append(Placeholder(
                    rect: rect,
                    card: MosaicPlaceholder.image(
                        .missing(tile.source, descriptor: descriptor),
                        size: rect.size
                    )
                ))
                continue
            }

// The window's own shape contained in the tile, not each axis clamped separately (that gives a shape that is neither, and a picture where the phone does not expect it). See MosaicTileFit.
            guard let pixelSize = MosaicTileFit.surface(
                sourceSize: descriptor.pixelSize,
                tilePixels: rect
            ) else {
// No size on the source or tile: nothing to capture into, and the card says what the tile holds.
                placeholders.append(Placeholder(
                    rect: rect,
                    card: MosaicPlaceholder.image(.empty(descriptor: descriptor), size: rect.size)
                ))
                continue
            }

            guard let configuration = try? CaptureEngine.configuration(
                for: descriptor,
                pixelSize: pixelSize,
                frameRate: layout.frameRate,
// The pointer is drawn by ScreenCaptureKit per tile: a mosaic has N windows it can be in and no single screen rectangle.
                showsCursor: true
            ) else {
// A configuration ScreenCaptureKit will not accept is the same as a source it will not filter.
                placeholders.append(Placeholder(
                    rect: rect,
                    card: MosaicPlaceholder.image(.empty(descriptor: descriptor), size: rect.size)
                ))
                continue
            }

// The rectangle belongs to the filter, not the configuration. See CaptureFilterPlan.
            if let sourceRect = filterPlan.sourceRect {
                configuration.sourceRect = sourceRect
            }

            tiles.append(
                Tile(
                    source: tile.source,
                    rect: rect,
                    pixelSize: pixelSize,
                    filter: filterPlan.filter,
                    configuration: configuration,
                    card: MosaicPlaceholder.Card(
                        content: .empty(descriptor: descriptor),
                        size: rect.size
                    )
                )
            )
        }

        return MosaicPlan(
            canvas: layout.canvas,
            frameRate: layout.frameRate,
            tiles: tiles,
            placeholders: placeholders
        )
    }
}

/// The one place that runs more than one capture at a time: ScreenCaptureKit has no filter for two displays or unrelated windows, so one stream per tile is composited into the picture the phone decodes.
/// Frames are pulled on a timer, not pushed on tile arrival: VideoEncoder needs increasing timestamps, and composing on the last tile to arrive would step back when a 60 fps window interleaved with a 15 fps one.
/// Neither buffer is ScreenCaptureKit's: its frame buffers belong to a pool reused while VideoToolbox still reads them, so each tile frame is copied on arrival and drawn from the copy.
/// The canvas comes from a CVPixelBufferPool, which will not hand back a buffer still referenced, so a tick the encoder has not finished with is skipped. Reusing one canvas buffer made frames of two pictures, which the client refused (the reason CapturePipeline/idleFramesEnabled is off).
final class MosaicCompositor: CaptureFrameSource, @unchecked Sendable {
    private let lock = NSLock()

/// Serial: VideoToolbox may not be handed two frames at once.
    private let queue = DispatchQueue(label: "pl.dmq.peering.capture.mosaic", qos: .userInitiated)

    /// Lets ``stop()`` tell whether it is already running on the queue, where waiting for that
    /// queue would deadlock instead of draining it.
    private static let queueKey = DispatchSpecificKey<UInt8>()

/// The only object here that touches the GPU. The working colour space is named because the canvas is encoded as 420v video-range YCbCr using the matrix ScreenCaptureKit assumed per tile; the default would put an sRGB assumption under it and shift colours.
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])

    private struct HeldFrame {
        let buffer: CVPixelBuffer
    }

/// An identity, not a place: built once per start(_:) and never reordered, and callbacks close over their index. Which rectangle a picture belongs in is engineForSlot's question.
    private var engines: [CaptureEngine] = []
    private var plan: MosaicPlan?
    private var isParked = false
/// Which engine stands behind each tile of plan. A reorder changes tile order but not engine order; permuting the held frames instead leaves every engine writing into another window's slot.
    private var engineForSlot: [Int] = []
    private var held: [HeldFrame?] = []
    private var dirty = false
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private var frameIndex: Int64 = 0
    private var deliveredCount = 0
    private var skippedTicks = 0
    private var deadTiles: Set<Int> = []

    private var firstCanvasDeadline: DispatchTime?
    private var firstCanvasAt: DispatchTime?
    private var firstCanvasSent = false
/// Bumped by every start and stop so in-flight work can tell whether its state is still wanted: a stop inside a start would otherwise leave streams and a timer running forever.
    private var generation = 0
/// From the frame geometry, not the colour: a capture with nothing to photograph says so in the frame attachment, and a window is allowed to be black, so a colour test would announce nothing to show over a dark editor.
    private var emptyTiles: Set<Int> = []
    private var _onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var _onIdle: (@Sendable (IdleSample) -> Void)?
    private var _onStop: (@Sendable (CaptureError) -> Void)?
    private var _onTileLost: (@Sendable (Int) -> Void)?
    private var _onTileUncapturable: (@Sendable (Int) -> Void)?

    init() {
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    // MARK: - What the pipeline reads

/// Zero idle is what this source is: the canvas is redrawn on its tick whether or not a tile changed. The host diagnosis branch for capturing with nothing new to send relies on idle samples.
    var statistics: CaptureEngine.Statistics {
        lock.withLock { CaptureEngine.Statistics(delivered: deliveredCount, idle: 0, unreadable: 0) }
    }

    var liveTileCount: Int {
        lock.withLock { held.compactMap { $0 }.count }
    }

    var onFrame: (@Sendable (CapturedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

/// Never called: a canvas is produced on a timer, which keeps a keyframe request from sitting unanswered on a still desktop.
    var onIdle: (@Sendable (IdleSample) -> Void)? {
        get { lock.withLock { _onIdle } }
        set { lock.withLock { _onIdle = newValue } }
    }

/// Only when every tile has stopped: one window closing must not end the mosaic, that tile goes black and stays black.
    var onStop: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onStop } }
        set { lock.withLock { _onStop = newValue } }
    }

/// Once per tile that stops being capturable or reports nothing to show. A capture noticing is the only evidence a window closed, and the phone cannot drop it from an arrangement until told.
    var onTileLost: (@Sendable (Int) -> Void)? {
        get { lock.withLock { _onTileLost } }
        set { lock.withLock { _onTileLost = newValue } }
    }

    // MARK: - Lifecycle

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

    // MARK: - Rearranging

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

    // MARK: - Tiles

/// Copied because the frame buffer belongs to a pool ScreenCaptureKit reuses once the callback returns, so keeping the reference would read memory that has become something else. Geometry comes along to answer whether the picture holds anything (see emptyTiles). index is the engine's, stable for the tile's life.
    private func retain(_ buffer: CVPixelBuffer, geometry: FrameGeometry?, at index: Int) {
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

    private func markDead(_ index: Int) {
        let (first, callback) = lock.withLock {
            (deadTiles.insert(index).inserted, _onTileLost)
        }
        if first { callback?(index) }
    }

    private func tileStopped(_ index: Int) {
        markDead(index)
// A stream that started then stopped is the same evidence as one that never delivered. See onTileUncapturable.
        lock.withLock { _onTileUncapturable }?(index)
        let (dead, total, callback) = lock.withLock { (deadTiles, engines.count, _onStop) }
        guard total > 0, dead.count >= total else { return }
        callback?(.streamStopped(code: 0, description: "Every window in this mosaic has stopped being captured."))
    }

    // MARK: - The canvas

    private func startTimer(_ plan: MosaicPlan) {
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

    // MARK: - Buffers

/// The allocation threshold turns back-pressure into a dropped tick: past it the pool refuses and tick() counts it. Three is the encoder queue depth plus the frame being drawn.
    private static func makePool(for canvas: CGSize) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferWidthKey: Int(canvas.width),
            kCVPixelBufferHeightKey: Int(canvas.height),
        ]
        let auxiliaries: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: 3,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            auxiliaries as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw CaptureError.encodingFailed("A canvas of \(Int(canvas.width))×\(Int(canvas.height)) could not be allocated.")
        }
        return pool
    }

/// Row by row: same-size buffers are not promised the same bytes per row (CoreVideo pads), and a plane copied as one block would shear sideways.
    private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { return nil }

        var destination: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &destination
        ) == kCVReturnSuccess, let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return nil }
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let bytes = min(sourceStride, destinationStride)
            for row in 0..<rows {
                memcpy(
                    to.advanced(by: row * destinationStride),
                    from.advanced(by: row * sourceStride),
                    bytes
                )
            }
        }
        return destination
    }
}
