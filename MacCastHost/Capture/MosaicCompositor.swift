import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MacCastKit
import RemoteCore
import ScreenCaptureKit
import os

private let mosaicLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Everything a mosaic needs to be captured, resolved against the catalogue.
///
/// Built by the pipeline, which is the only place that holds both the resolver and the
/// catalogue, and consumed by the compositor, which owns the streams from there on. A tile
/// whose source has gone is left out of `tiles` rather than failing the plan: a mosaic of six
/// windows where one has been closed is five pictures and a black rectangle, which is what the
/// user can see and act on, where an error is a mosaic that never appears.
struct MosaicPlan: @unchecked Sendable {
    struct Tile: @unchecked Sendable {
        let source: CaptureSource
        /// Where the tile is drawn, in canvas pixels, measured from the canvas's top left.
        let rect: CGRect
        /// The size this tile's own stream is built at: the tile's pixels in the canvas, never
        /// more than the source's own. This is the whole of the mosaic's cost control, because
        /// ScreenCaptureKit scales the content down for us.
        let pixelSize: CGSize
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        /// What to draw in this tile when it has no picture of its own: a stream that will not
        /// start, or one that has stopped before it ever produced a frame. Drawn on first use
        /// rather than here. See ``MosaicPlaceholder/Card``.
        let card: MosaicPlaceholder.Card
    }

    /// A tile the plan could not build a capture for, and the card that stands in for it.
    ///
    /// **Kept out of `tiles` because there is no stream to keep in step with one.** Everything
    /// above that array treats a tile as a capture — an engine each, an entry each in the held
    /// frame array, an index each in the dead set — so a tile with no filter would be an engine
    /// that can never start and an index nothing will ever fill. What it needs is the one thing
    /// the compositor does with any tile in the end: somewhere to draw a card.
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
    /// Resolves a client's layout into streams, one per tile.
    ///
    /// **A tile whose source has gone is left out of the captures and kept on the canvas**, as a
    /// card that says so: a window closed between the phone drawing the arrangement and the Mac
    /// building it is the ordinary way a mosaic starts, not an error worth failing the plan over —
    /// and a black rectangle with a border around it tells the user nothing at all. See
    /// ``Placeholder`` and ``MosaicPlaceholder``.
    ///
    /// The exception is every tile, which is a mosaic with nothing in it, and the caller says so.
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
                // **The source is still in the client's arrangement and not in the catalogue**,
                // which is what "there is nothing to capture here" means at this end. The card is
                // built whether or not the descriptor was found: the process table still knows the
                // name and the icon of an application that is running with nothing open, and that
                // is the case this exists for.
                placeholders.append(Placeholder(
                    rect: rect,
                    card: MosaicPlaceholder.image(
                        .missing(tile.source, descriptor: descriptor),
                        size: rect.size
                    )
                ))
                continue
            }

            // **The window's own shape, contained in the tile's pixels.** Not each axis clamped
            // separately, which is what this was: that produces a surface whose shape is neither
            // the tile's nor the window's, leaves ScreenCaptureKit a crop to choose, and puts the
            // picture somewhere other than where the phone works out that it is — which is the
            // rectangle the zoom a tap travels with is aimed at. See ``MosaicTileFit`` for the
            // rule and why the two ends have to read the same one.
            guard let pixelSize = MosaicTileFit.surface(
                sourceSize: descriptor.pixelSize,
                tilePixels: rect
            ) else {
                // A source with no size, or a tile with none. There is nothing to capture into,
                // and the card says what the tile holds rather than leaving a hole in the canvas.
                placeholders.append(Placeholder(
                    rect: rect,
                    card: MosaicPlaceholder.image(.empty(descriptor: descriptor), size: rect.size)
                ))
                continue
            }

            guard var configuration = try? CaptureEngine.configuration(
                for: descriptor,
                pixelSize: pixelSize,
                frameRate: layout.frameRate,
                // The pointer is drawn into each tile by ScreenCaptureKit rather than by this
                // app's overlay: on a mosaic there are N windows the pointer can be inside and
                // no single screen rectangle saying where it is in the composite.
                showsCursor: true
            ) else {
                // A configuration ScreenCaptureKit will not accept is the same answer as a source
                // it will not filter: this tile has no picture, and the card says so rather than
                // leaving a hole in the canvas that looks like a bug in the picture.
                placeholders.append(Placeholder(
                    rect: rect,
                    card: MosaicPlaceholder.image(.empty(descriptor: descriptor), size: rect.size)
                ))
                continue
            }

            // The rectangle belongs to the filter, so it is set here rather than built into the
            // configuration. See ``CaptureFilterPlan``.
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
                    // A tile whose stream starts and then stops, or delivers frames with no content
                    // in them, has this drawn in it instead of a stale picture. See ``draw``.
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

/// Several of the Mac's sources drawn into one canvas, presenting itself as one frame source.
///
/// **The one thing in this app that runs more than one capture at a time.** ScreenCaptureKit
/// has no filter that takes two displays, or two unrelated windows, so a mosaic is one stream
/// per tile composited per frame into the single picture the phone can decode. It conforms to
/// ``CaptureFrameSource`` like any other source, so everything above it — the frame intake, the
/// encoder, the keyframe bookkeeping, the resize check — does not know it is looking at N
/// captures rather than one.
///
/// **Frames are pulled on a timer rather than pushed as tiles arrive**, and the second reason is
/// the one that decides it. The obvious one is that a canvas has one rate while its tiles each
/// have their own, so something has to choose the moment. The real one is ordering:
/// ``VideoEncoder`` requires presentation timestamps that increase, and composing on whichever
/// tile arrived last would take the canvas's timestamp backwards the moment a 60 fps window
/// interleaved with a 15 fps one. A counter driven by the timer cannot go backwards.
///
/// ## Two buffers, and neither of them is ScreenCaptureKit's
///
/// **A frame's buffer belongs to a pool ScreenCaptureKit reuses, and VideoToolbox is still
/// reading it when the next one arrives** — see the note on ``CapturedFrame``. That is fine for
/// a pipeline that hands one straight to the encoder, and fatal for a compositor, which reads a
/// tile's picture up to a tick later. So each tile's frame is **copied on arrival into a buffer
/// this object owns**, and the copy is what is drawn from.
///
/// The canvas is the same story from the other end, and it is the failure
/// ``CapturePipeline/idleFramesEnabled`` was turned off for: a compositor that reused one canvas
/// buffer would hand the encoder the same memory every tick and rewrite it while VideoToolbox
/// was still reading the previous frame, and the client would get a frame made of two pictures,
/// refuse it, and spend the rest of the session accepting keyframes only. A ``CVPixelBufferPool``
/// fixes it by construction: it will not hand back a buffer that is still referenced, so a tick
/// the encoder has not finished with is **skipped** rather than corrupted.
final class MosaicCompositor: CaptureFrameSource, @unchecked Sendable {
    private let lock = NSLock()

    /// Frames are composed and delivered on this queue, which is serial for the same reason
    /// every other source's is: VideoToolbox may not be handed two frames at once.
    private let queue = DispatchQueue(label: "pl.dmq.peering.capture.mosaic", qos: .userInitiated)

    /// Lets ``stop()`` tell whether it is already running on the queue, where waiting for that
    /// queue would deadlock instead of draining it.
    private static let queueKey = DispatchSpecificKey<UInt8>()

    /// The context the tiles are drawn with. One, and thread-safe by contract: it is the only
    /// object here that touches the GPU.
    ///
    /// Created with the working colour space named rather than left to the display, because the
    /// canvas is encoded as `420v` video-range YCbCr and the colour matrix that conversion uses
    /// is the one ScreenCaptureKit already assumed per tile. Leaving this to default would put
    /// an sRGB assumption under a video-range picture and shift every colour slightly, which is
    /// the kind of wrong that looks like a phone that renders badly.
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])

    /// A tile's last picture, in a buffer this object owns. See the note on the type.
    private struct HeldFrame {
        let buffer: CVPixelBuffer
    }

    /// The captures, in the order they were built, which is the order they are always in.
    ///
    /// **This array is an identity, not a place.** It is built once per ``start(_:)`` and never
    /// reordered, and each tile's callbacks close over their own index into it — so an engine's
    /// index is the only thing about a tile that a rearrangement leaves alone. Which rectangle
    /// its picture belongs in is ``engineForSlot``'s question, and that has a different answer
    /// after every reorder.
    private var engines: [CaptureEngine] = []
    private var plan: MosaicPlan?
    /// Set while the captures are being kept without a canvas being drawn. See ``park()``.
    private var isParked = false
    /// Which engine stands behind each tile of ``plan``, in the plan's own order.
    ///
    /// **The mapping the rearrangement was relying on and did not have.** The tiles are the
    /// client's order; the engines are the order the streams were built in; a reorder changes the
    /// first and not the second. Held implicitly — by permuting the retained frames and trusting
    /// the callbacks to follow — a reorder left every engine writing into another window's slot,
    /// so the canvas came back in the old arrangement as soon as each engine had delivered once,
    /// and mixed while they arrived one at a time. Which is a reorder that does not reorder, and
    /// a shuffle.
    private var engineForSlot: [Int] = []
    /// A tile's last picture, by **engine** index. See ``engines``.
    private var held: [HeldFrame?] = []
    /// Set when a tile's picture has arrived since the canvas was last drawn.
    private var dirty = false
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private var frameIndex: Int64 = 0
    private var deliveredCount = 0
    private var skippedTicks = 0
    /// Tiles whose own capture has stopped, by **engine** index. See ``engines``.
    private var deadTiles: Set<Int> = []

    /// When the first canvas stops waiting for the rest of its tiles. See ``tick()``.
    private var firstCanvasDeadline: DispatchTime?
    /// When that wait began, and whether it is over, for the one line ``tick()`` logs about it.
    private var firstCanvasAt: DispatchTime?
    private var firstCanvasSent = false
    /// Bumped by every start and every stop, so work that is mid-flight can tell whether the
    /// state it is about to publish is still wanted.
    ///
    /// **A stop that lands inside a start used to leave everything behind.** The engines were
    /// published after all of them had started, so a `stop()` arriving during that loop stopped
    /// the *previous* generation — or nothing at all on the first start — and the new streams
    /// finished coming up with nothing holding them: six captures and a timer, running for the
    /// life of the process, copying every frame of every window into a buffer nobody draws.
    private var generation = 0
    /// Tiles whose own capture says it has nothing in it, by **engine** index. See ``engines``.
    ///
    /// **From the frame's geometry rather than from the colour of it**, and that distinction is
    /// the whole of why this is honest. A capture that is running and has nothing to photograph —
    /// an application whose windows have all been closed, which ScreenCaptureKit goes on streaming
    /// as a frame with an empty content rectangle — says so in the frame's own attachment. The
    /// colour of the picture says nothing: a window is allowed to be black, and a tile that
    /// announced "nothing to show" over somebody's dark editor would be the app being confidently
    /// wrong about a picture it can see perfectly well.
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

    /// Canvases delivered, and never an idle sample.
    ///
    /// **Zero idle is not a missing counter, it is what this source is.** A tile that has not
    /// changed produces no frame, but the canvas is redrawn on its tick either way, so nothing
    /// here is ever *waiting* for the screen to move. That matters to the host's own diagnosis:
    /// the "capturing, nothing new to send yet" branch in ``VideoCoordinator/reportNoFrames``
    /// is taken on idle samples without delivered frames, and a compositor that reported idle
    /// ticks would take it while every one of its six tiles had failed to start.
    var statistics: CaptureEngine.Statistics {
        lock.withLock { CaptureEngine.Statistics(delivered: deliveredCount, idle: 0) }
    }

    /// How many tiles have produced a picture at all, for the host window's status line.
    var liveTileCount: Int {
        lock.withLock { held.compactMap { $0 }.count }
    }

    var onFrame: (@Sendable (CapturedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// Never called: a canvas is produced on a timer whether or not anything on it moved, which
    /// is what keeps a keyframe request from sitting unanswered on a still desktop. See the note
    /// on the type.
    var onIdle: (@Sendable (IdleSample) -> Void)? {
        get { lock.withLock { _onIdle } }
        set { lock.withLock { _onIdle = newValue } }
    }

    /// Called when every tile has stopped, which is the only mosaic-wide failure there is.
    ///
    /// **One tile dying is not this.** Windows get closed while a mosaic is on screen, and a
    /// mosaic that ended because one of its six windows went away would be the app punishing the
    /// user for something they did on purpose. That tile goes black and stays black.
    var onStop: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onStop } }
        set { lock.withLock { _onStop = newValue } }
    }

    /// Called once for each tile that stops being capturable, or that starts reporting that it
    /// has nothing to show.
    ///
    /// **Nothing else on the Mac knows a window has closed.** There is no notification for it, so
    /// a capture noticing is the only evidence there is, and the phone cannot take a closed
    /// window out of an arrangement until somebody tells it the window is gone. See
    /// ``CapturePipeline``.
    var onTileLost: (@Sendable (Int) -> Void)? {
        get { lock.withLock { _onTileLost } }
        set { lock.withLock { _onTileLost = newValue } }
    }

    // MARK: - Lifecycle

    func start(_ request: CaptureStartRequest) async throws {
        guard case .mosaic(let plan) = request else {
            // Unreachable by construction: the pipeline builds the plan it passes. Stated
            // rather than crashed so a future backend cannot make it reachable in silence.
            throw CaptureError.streamFailed("The mosaic compositor was started with something that is not a mosaic.")
        }

        let pool = try Self.makePool(for: plan.canvas)

        // A timer from a start that was never stopped. Cancelled here rather than left for
        // ``startTimer(_:)`` to overwrite: a resumed dispatch source that nothing holds is not
        // deallocated, it goes on firing ticks at a plan this object no longer has.
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
            // Identity, and the only moment the two domains are the same thing: engine `i` was
            // built for tile `i` of the arrangement that is being started. See ``engineForSlot``.
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

        // The streams, one per tile. Each engine delivers on its own queue, so arrival order
        // between tiles is not an order at all — which is exactly why the canvas is composed on a
        // tick rather than on arrival.
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

        // **Published before they are started, so a stop can reach them.** Held back until every
        // stream was up, a `stop()` arriving in the middle of the loop below had nothing to stop:
        // it cleared an array that was still empty, the tiles came up anyway, and they went on
        // capturing with nothing holding a reference to them. See ``generation``.
        lock.withLock {
            guard self.generation == generation else { return }
            self.engines = engines
            // A tile whose stream never delivers must not hold the whole picture, so the wait for
            // the rest of them is bounded. See ``tick()``.
            // **Short, because the deadline is a decision rather than a wait.** The six streams
            // start over about a third of a second and then each delivers a first frame, so
            // everything that is coming has come well inside this; what is left after it is a
            // tile that is never going to, and ``tick()`` stops waiting for it for good. A bound
            // that is generous instead of decisive is the arrangement held back for a window that
            // will never appear.
            self.firstCanvasAt = DispatchTime.now()
            self.firstCanvasDeadline = DispatchTime.now() + .milliseconds(700)
            self.firstCanvasSent = false
        }

        // **The timer before the streams, not after them.** A tick with no picture yet is already
        // a no-op — see ``tick``, which waits for one tile — so starting it here costs nothing and
        // buys the whole difference between a mosaic that appears when the first window is up and
        // one that appears when the slowest of six has started. ScreenCaptureKit takes a few
        // hundred milliseconds per stream, and they used to be taken one after another.
        startTimer(plan)

        // Start one at a time. ScreenCaptureKit accepts several live streams, but concurrent
        // `startCapture()` calls can interrupt the capture service itself: one start is refused,
        // then every stream that did start stops with `application connection being interrupted`.
        // The timer is already running, so the first tile appears as soon as it is ready while the
        // remaining tiles come up behind it; serialising only the setup calls does not hold the
        // first usable mosaic back.
        for (index, tile) in plan.tiles.enumerated() {
            guard isCurrent(generation) else { break }
            do {
                try await engines[index].start(
                    .stream(filter: tile.filter, configuration: tile.configuration)
                )
            } catch {
                // A tile that will not start leaves its rectangle black and the rest of the mosaic
                // running. It is counted as dead, so nothing waits for it.
                let failure = CaptureError.from(error)
                mosaicLog.error("mosaic tile \(index, privacy: .public) did not start: \(String(describing: failure), privacy: .public)")
                if isCurrent(generation) { markDead(index) }
            }
        }

        mosaicLog.notice("mosaic started: \(plan.tiles.count, privacy: .public) tiles, \(plan.placeholders.count, privacy: .public) empty, at \(Int(plan.canvas.width), privacy: .public)×\(Int(plan.canvas.height), privacy: .public)")
    }

    /// Whether the work that was started under `generation` is still the work that is wanted.
    ///
    /// One question, asked at every point a start could otherwise publish state a stop has already
    /// given up on. See ``generation``.
    private func isCurrent(_ generation: Int) -> Bool {
        lock.withLock { self.generation == generation }
    }

    func stop() async {
        // The timer first, so no tick is in flight while the engines are torn down, and the
        // engines second. Cancelling a timer whose handler is already running waits for it on
        // this queue, which is why the drain below is needed rather than a plain cancel.
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            let current = self.timer
            self.timer = nil
            return current
        }
        timer?.cancel()
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            queue.sync {}
        }

        // **Before the engines are taken, so a start in flight knows at the same moment.** Taking
        // them and bumping the generation are one decision — "this generation is over" — and a
        // start that checked in between the two would go on building its streams.
        let engines = lock.withLock { () -> [CaptureEngine] in
            self.generation += 1
            let current = self.engines
            self.engines = []
            self.engineForSlot = []
            return current
        }
        // **Together, and this one is on the critical path of every source switch.** Leaving a
        // mosaic for one of its windows stops every tile's stream before the new one is built, and
        // one at a time that is the teardown multiplied by the number of windows — half a second
        // or more of the user looking at a picture that has not changed yet. Nothing here depends
        // on the order, and the frames that arrive while it runs are dropped by a compositor with
        // no plan. See ``stop()``'s note on what the drain above is for.
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

    /// Called once for a tile whose capture produced no picture at all and is not going to, by
    /// **engine** index.
    ///
    /// **A different thing from ``onTileLost``, and the difference is the whole reason it exists.**
    /// A tile that reports an empty content rectangle has a stream that is running and delivering,
    /// and a window it belongs to that is open: opening it works, and it is simply empty. A tile
    /// that has produced nothing at all is one this Mac cannot capture, which is a fault in the
    /// window rather than in the arrangement, and the catalogue is where that has to be answered.
    /// See ``CaptureSourceResolver/markUncapturable(_:)``.
    var onTileUncapturable: (@Sendable (Int) -> Void)? {
        get { lock.withLock { _onTileUncapturable } }
        set { lock.withLock { _onTileUncapturable = newValue } }
    }

    /// The source behind one engine, for a caller that has to name what a tile did.
    ///
    /// The engine is what the callbacks are indexed by, and the client's arrangement is the order
    /// they were built in only until the first rearrangement. See ``engineForSlot``.
    func source(forEngine index: Int) -> CaptureSource? {
        lock.withLock {
            guard let plan,
                  let slot = engineForSlot.firstIndex(of: index),
                  plan.tiles.indices.contains(slot)
            else { return nil }
            return plan.tiles[slot].source
        }
    }

    /// Whether one of these captures is the source named.
    ///
    /// The question ``CapturePipeline`` asks before it leaves an arrangement for one of the
    /// arrangement's own windows, which is the one departure that does not have to cost anything.
    func holdsTile(_ source: CaptureSource) -> Bool {
        lock.withLock { plan?.tiles.contains { $0.source == source } ?? false }
    }

    /// Stops drawing canvases and keeps every capture behind them.
    ///
    /// **The way back out of a tile is the one source switch this can pay for.** An arrangement
    /// whose windows are still running is a canvas built out of frames that are already there, so
    /// coming back is one composite rather than six streams and the wait for their first frames.
    /// Nothing is torn down and nothing is rebuilt; only the timer stops.
    ///
    /// The captures go when the arrangement does. A caller parks this only for a window that is
    /// one of its own tiles, so anything else, another source or a disconnect, reaches ``stop()``
    /// and takes the streams with it.
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

    /// Whether a new arrangement is the same captures in different rectangles.
    ///
    /// **The captures are the expensive part and none of them belongs to the canvas.** Turning the
    /// phone keeps every window exactly where it was on the Mac and changes only where its picture
    /// is drawn on the phone — and the same is true of going back to an arrangement from one of its
    /// tiles. What that *should* cost is arithmetic, and what it cost was six streams stopped and
    /// six started, which is a second and a half of black over a change nothing about the Mac had
    /// made.
    ///
    /// So the question this asks is the narrowest one that is still safe: the same sources, in the
    /// same order, at the same frame rate. The tile's own surface size is deliberately *not* part
    /// of it — a tile that changed shape is a stream that needs re-pointing, not a stream that
    /// needs replacing, and ``replan(_:)`` does exactly that.
    /// **Order does not matter**, which is a change of mind worth recording: a reorder is the same
    /// captures in the same rectangles as each other, and the whole point of the check is that the
    /// *captures* are what is expensive. Which of them goes in which rectangle belongs to the
    /// canvas, and ``replan(_:)`` reads the new arrangement to find out — so a tile dragged from
    /// one corner to another costs a re-composite rather than six streams built again.
    func canReuseCaptures(for plan: MosaicPlan) -> Bool {
        let (current, engines) = lock.withLock { (self.plan, self.engines) }
        guard let current,
              engines.count == plan.tiles.count,
              current.frameRate == plan.frameRate,
              current.tiles.count == plan.tiles.count
        else { return false }
        return Set(current.tiles.map(\.source)) == Set(plan.tiles.map(\.source))
    }

    /// Redraws the same captures into a different canvas.
    ///
    /// **A tile whose shape changed is re-pointed rather than restarted**, which is the whole point
    /// of the exercise: an arrangement of the same windows on a phone that has been turned is the
    /// same six captures at six new surface shapes, and ScreenCaptureKit can change a stream's
    /// shape in place. A tile that will not take the new shape keeps the old one — its picture
    /// letterboxed into a rectangle of a different aspect is a slightly soft tile, where stopping
    /// the stream would be a tile that is black until everything is built again.
    func replan(_ plan: MosaicPlan) async throws {
        let pool = try Self.makePool(for: plan.canvas)
        let (current, engines, previous) = lock.withLock {
            (self.plan, self.engines, self.engineForSlot)
        }

        // **Each engine is found by its source, not by its place.** An engine belongs to a window
        // and not to a rectangle: the compositor draws whatever arrives from it into wherever the
        // client says, so a window that has moved to another slot keeps the stream it had.
        //
        // Found through the *previous* arrangement and its mapping rather than by counting slots,
        // which is the same answer after one rearrangement and a different one after two. A slot
        // is not an engine, and the second rearrangement of a session is where the two were
        // assumed to still be the same thing. See ``MacCastKit/MosaicRearrangement``.
        //
        // Nothing to rearrange onto: every window in this plan would have to be drawn from an
        // engine nobody can name. The caller's answer is to build the mosaic again rather than to
        // draw six windows into six arbitrary slots, so the arrangement goes on being one the
        // compositor can describe. Unreachable through ``canReuseCaptures(for:)``, which is why it
        // is stated rather than handled.
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

        // **Together, for the same reason the streams are started together.** A turn of the phone
        // changes the shape of every tile at once, and one re-shape at a time is that change
        // multiplied by the number of windows: eight tiles, eight awaits, and the new canvas
        // arrives a third of a second after the phone has finished turning rather than during it.
        // Each of these is a call into ScreenCaptureKit for one stream and nothing is shared
        // between them.
        // The tiles that need re-pointing, as an index and the engine for it. The configuration
        // itself is read inside the task from the plan — both of these are sendable and a
        // `SCStreamConfiguration` is not, and the plan is the one place the whole of it lives.
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
            // **The frames are not moved, and that is the whole of the fix.** They are held by
            // engine, and an engine goes on being the same engine; what changes is which slot it
            // is drawn in, which is one array of indices. The rearrangement used to permute the
            // held frames into the new slot order instead — and the callbacks, which are indexed
            // by engine, went on writing in the order the streams had been built in, so each tile
            // was overwritten by another window's picture as the next frame from each engine
            // arrived.
            self.engineForSlot = engineForSlot
            self.plan = plan
            self.pool = pool
            // The canvas is new and so is the encoder behind it, so the timeline starts again with
            // it — a counter left running would put the first frame of the new canvas at a
            // timestamp the encoder has not been told to expect.
            self.frameIndex = 0
            self.dirty = true
            let parked = self.isParked
            self.isParked = false
            return parked
        }

        // **A parked arrangement comes back on the next tick.** Every tile that can deliver has
        // already delivered, so the wait below has nothing left to wait for and the canvas goes out
        // at the frame rate rather than at the deadline. The bound is armed anyway, for a tile that
        // died while the arrangement was parked.
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

    /// Keeps a tile's picture, in a buffer of our own.
    ///
    /// **This copy is the whole reason the type has a buffer story.** The frame's buffer belongs
    /// to a pool ScreenCaptureKit reuses the moment the callback returns, and the compositor
    /// reads it on a later tick, so taking the reference would be reading memory that has since
    /// become something else. Two planes of `420v` at tile size is a few hundred kilobytes, and
    /// the alternative is a picture made of two different moments.
    ///
    /// The frame's geometry comes with it for the one question the buffer cannot answer: whether
    /// there is anything in the picture. See ``emptyTiles``.
    ///
    /// **`index` is the engine's, which is the one index here that means the same thing for the
    /// whole life of the tile.** A rearrangement moves windows between slots and moves no engines
    /// at all, so a callback that wrote by slot would be writing into another window's rectangle
    /// from the moment the arrangement changed.
    private func retain(_ buffer: CVPixelBuffer, geometry: FrameGeometry?, at index: Int) {
        guard let copy = Self.copy(buffer) else { return }
        // An empty content rectangle is the capture saying "there is nothing here", which is what
        // an application whose last window has closed reports. A frame with no geometry at all is
        // a different answer — nobody said — and leaves the tile as it was: a card drawn over a
        // picture because an attachment was missing would be this app inventing a fault.
        let empty = geometry?.contentRect?.isEmpty ?? false

        let (lost, callback) = lock.withLock {
            () -> (Bool, (@Sendable (Int) -> Void)?) in
            guard index < held.count else { return (false, nil) }
            held[index] = HeldFrame(buffer: copy)
            dirty = true
            // **A tile that is delivering is not dead**, whatever a past deadline decided. A window
            // that was not being rendered when the canvas was built can start being rendered, and
            // without this its card would stay up for the rest of the session over a live picture.
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

    /// One tile's stream ended. Only a mosaic where every tile has now stopped is a failure.
    private func tileStopped(_ index: Int) {
        markDead(index)
        // A stream that started and then stopped is the same evidence as one that never delivered:
        // this source is not producing pictures. See ``onTileUncapturable``.
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

    /// One canvas, if the encoder is ready for one.
    ///
    /// **Every tick draws, whether or not a tile moved**, and that is deliberate. A keyframe
    /// request made by a client that has just attached has to be answered with a *frame*, and a
    /// compositor that only drew on change would leave a still mosaic answering nothing at all —
    /// the same trap that keeps a real stream from ever going idle in a way the client can see.
    /// Identical frames cost the encoder almost nothing: it emits a small delta, not a picture.
    private func tick() {
        let (plan, pool) = lock.withLock { (self.plan, self.pool) }
        guard let plan, let pool, !plan.tiles.isEmpty else { return }

        // Nothing has arrived from any tile yet: there is no picture to compose, and sending a
        // black canvas would be this app inventing a failure the client cannot tell from a Mac
        // that is asleep. The first canvas goes out as soon as *one* tile has a frame, which is
        // also what keeps the first-frame watchdog's question ("did any picture ever arrive")
        // answerable per mosaic rather than per tile.
        // **The first canvas waits for its tiles rather than for the first of them.** Sent as soon
        // as one tile had a picture, it arrived with the other five black — and the phone cannot
        // tell a tile that has not been captured from a window that is black. The tile that had a
        // picture is the one the user has just left, so the window they were looking at blinked
        // out of the arrangement and came back a second later. Waiting costs a few hundred
        // milliseconds once, and it is the difference between a mosaic that arrives and one that
        // assembles itself in front of somebody.
        //
        // Bounded, because a tile whose stream starts and then says nothing must not hold the
        // whole picture: past the deadline the canvas goes out with whatever is ready.
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

        // **Past the deadline a tile that has never delivered is not slow, it is one that is never
        // going to.** A window that is not on screen — hidden, minimised, on a Space that is not
        // showing — starts a stream and then says nothing, and its capture is enumerated anyway
        // because the picker deliberately lists windows on every Space. Waiting longer only makes
        // the whole arrangement later: measured, a mosaic of six waited the full bound for one
        // such window on every single build. Marked dead it draws a card in its rectangle, stops
        // the canvas waiting, and tells the phone the window has gone so it can take it out of the
        // arrangement — which is what the user wanted from that tile in the first place.
        for index in expired { markDead(index) }
        // **And said out loud as the stronger fact it is.** Marked dead is what the canvas does
        // with the tile; this is what the Mac knows about the *source*, and it is the only place
        // anything finds out. After the loop above, so the catalogue invalidation that comes with
        // a lost tile cannot arrive behind it and take the report with it.
        for index in expired { lock.withLock { _onTileUncapturable }?(index) }
        guard started, settled else { return }

        // **Said out loud, because "the canvas arrived empty" and "the canvas was late" are the
        // same complaint from the phone and want opposite fixes.** A canvas that goes out before
        // its tiles is a mosaic that assembles itself in front of the user; one held too long is a
        // wait. This is the line that says which is happening.
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
            // The encoder has not finished with the buffers it has, which is back-pressure
            // rather than an error: the tick is dropped, and the next one draws the same tiles.
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
            // A canvas is of no screen, and its geometry is the one the pipeline published when
            // the source started: this reports nothing per frame for the same reason a display
            // reports nothing per frame. See ``CaptureSource/contentMovesOnItsOwn``.
            geometry: FrameGeometry(contentRect: nil, contentScale: nil, scaleFactor: nil, screenRect: nil)
        )
        lock.withLock { _onFrame }?(frame)
    }

    /// Draws every tile into the canvas, each scaled to fit its rectangle.
    ///
    /// **A tile with no picture gets a card instead of a hole**, and there are three ways to have
    /// no picture: the plan could not build a capture for the tile at all (``MosaicPlan/Placeholder``),
    /// the tile's stream has ended, or the capture is running and its own content rectangle says
    /// it has nothing to show (``emptyTiles``). All three used to be a black rectangle or a
    /// frozen picture, neither of which says anything — and the rectangle is the one thing a user
    /// can only read as this app having failed at something.
    ///
    /// **A tile whose stream has ended loses its last picture to the card**, which is deliberate
    /// and is the case this was written for: a window closed while the mosaic was on screen stops
    /// its stream, and what was left was a photograph of a window that no longer exists with
    /// nothing on it to say so. The last frame is not a picture of anything any more.
    private func draw(plan: MosaicPlan, into canvas: CVPixelBuffer) {
        let bounds = CGRect(origin: .zero, size: plan.canvas)
        let (frames, empty, dead, mapping) = lock.withLock {
            (held, emptyTiles, deadTiles, engineForSlot)
        }

        var image = CIImage(color: .black).cropped(to: bounds)
        for (index, tile) in plan.tiles.enumerated() {
            // **Two index spaces meet here, and this is the only line that has to know.** The loop
            // is over the arrangement the client asked for; the picture, the dead flag and the
            // empty flag all belong to an engine, which is a window rather than a slot. See
            // ``engineForSlot``.
            guard index < mapping.count else { continue }
            let engine = mapping[index]

            if empty.contains(engine) || dead.contains(engine),
               let card = tile.card.picture.map({ Self.place($0, in: tile.rect, canvas: plan.canvas) }) {
                image = card.composited(over: image)
                continue
            }
            // Nothing has arrived yet. Not a card: a tile that is merely slow to start is a
            // mosaic still coming up, and a card over it would be this app reporting a fault
            // that lasts a few hundred milliseconds.
            guard engine < frames.count, let frame = frames[engine] else { continue }
            let picture = CIImage(cvPixelBuffer: frame.buffer)
            image = Self.place(picture, in: tile.rect, canvas: plan.canvas).composited(over: image)
        }

        // The tiles that have no stream at all, which are not in the loop above because there is
        // nothing to hold a frame for them.
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

    /// Scales a tile's picture to fit its rectangle, centred, and puts it where the client said.
    ///
    /// **Letterboxed rather than stretched**, because a tile is a window and a stretched window
    /// is a window whose text is the wrong shape. Every tile keeps its own aspect ratio and the
    /// black around it is the canvas showing through.
    ///
    /// The vertical flip is here and nowhere else: a tile's rectangle is measured from the top
    /// left of the canvas, which is the client's space and the one the whole layout is expressed
    /// in, while CoreImage puts its origin at the bottom left. Converting once, at the point the
    /// two spaces meet, is what keeps every other line in this file thinking in one of them.
    ///
    /// **Internal rather than private so the probe can check it**, which it does with two solid
    /// colours and no ScreenCaptureKit at all: a flip that is wrong puts the first tile in the
    /// bottom-left of the canvas, and nothing above this function can tell that from a Mac
    /// showing something upside down. See `Tools/CaptureProbe --compose-check`.
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

    /// A pool for the canvas, with a ceiling on how many it will hold.
    ///
    /// The allocation threshold is what turns back-pressure into a dropped tick instead of an
    /// unbounded pile of canvases: past it, ``CVPixelBufferPoolCreatePixelBuffer`` refuses, and
    /// ``tick()`` counts the tick and waits for the next one. Three is the encoder's own
    /// queue depth, plus one for the frame being drawn.
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

    /// A copy of a `420v` buffer, in storage this object owns.
    ///
    /// Row by row rather than plane at a time, because two `CVPixelBuffer`s of the same size
    /// are not promised the same bytes per row: CoreVideo pads for alignment, and a plane copied
    /// as one block would be a picture sheared sideways from the first row it drifted on.
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
