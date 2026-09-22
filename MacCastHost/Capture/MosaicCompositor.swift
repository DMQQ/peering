import CoreImage
import CoreMedia
import CoreVideo
import Foundation
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
    }

    let canvas: CGSize
    let frameRate: Int
    let tiles: [Tile]
}

extension MosaicPlan {
    /// Resolves a client's layout into streams, one per tile.
    ///
    /// **A tile whose source has gone is left out rather than failing the plan**, and its
    /// rectangle stays black: a window closed between the phone drawing the arrangement and the
    /// Mac building it is the ordinary way a mosaic starts, not an error worth showing anybody.
    /// The exception is every tile, which is a mosaic with nothing in it, and the caller says so.
    static func make(
        layout: MosaicLayout,
        catalog: CaptureCatalog,
        resolver: CaptureSourceResolver
    ) -> MosaicPlan {
        var tiles: [Tile] = []

        for tile in layout.tiles {
            guard let descriptor = catalog.descriptor(for: tile.source),
                  let filterPlan = try? resolver.makeFilter(for: tile.source)
            else { continue }

            let rect = tile.rect.pixels(in: layout.canvas)
            // **Never more pixels than the source has, and never more than the tile is drawn
            // at.** The first is what keeps a mosaic from asking the WindowServer to scale a
            // 400-point window up to a tile's worth of pixels nobody can see more of; the
            // second is the whole cost control, because it makes a six-tile canvas six small
            // captures rather than six display-sized ones.
            //
            // Even, both ways, and this is load-bearing rather than tidiness: ScreenCaptureKit
            // delivers a surface of exactly the configured size, the encoder rounds down to
            // even, and the pipeline's resize check compares the two — so an odd tile is an
            // encoder rebuilt on every frame of every tile. See ``CapturePipeline/encode(_:)``.
            func even(_ value: CGFloat) -> CGFloat {
                max(2, (value.rounded(.down) / 2).rounded(.down) * 2)
            }
            let pixelSize = CGSize(
                width: min(even(rect.width), even(descriptor.pixelSize.width)),
                height: min(even(rect.height), even(descriptor.pixelSize.height))
            )

            guard var configuration = try? CaptureEngine.configuration(
                for: descriptor,
                pixelSize: pixelSize,
                frameRate: layout.frameRate,
                // The pointer is drawn into each tile by ScreenCaptureKit rather than by this
                // app's overlay: on a mosaic there are N windows the pointer can be inside and
                // no single screen rectangle saying where it is in the composite.
                showsCursor: true
            ) else { continue }

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
                    configuration: configuration
                )
            )
        }

        return MosaicPlan(canvas: layout.canvas, frameRate: layout.frameRate, tiles: tiles)
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

    private var engines: [CaptureEngine] = []
    private var plan: MosaicPlan?
    private var held: [HeldFrame?] = []
    /// Set when a tile's picture has arrived since the canvas was last drawn.
    private var dirty = false
    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private var frameIndex: Int64 = 0
    private var deliveredCount = 0
    private var skippedTicks = 0
    private var deadTiles: Set<Int> = []

    private var _onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var _onIdle: (@Sendable (IdleSample) -> Void)?
    private var _onStop: (@Sendable (CaptureError) -> Void)?

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

    // MARK: - Lifecycle

    func start(_ request: CaptureStartRequest) async throws {
        guard case .mosaic(let plan) = request else {
            // Unreachable by construction: the pipeline builds the plan it passes. Stated
            // rather than crashed so a future backend cannot make it reachable in silence.
            throw CaptureError.streamFailed("The mosaic compositor was started with something that is not a mosaic.")
        }

        let pool = try Self.makePool(for: plan.canvas)

        lock.withLock {
            self.plan = plan
            self.pool = pool
            self.held = Array(repeating: nil, count: plan.tiles.count)
            self.dirty = false
            self.frameIndex = 0
            self.deliveredCount = 0
            self.skippedTicks = 0
            self.deadTiles = []
        }

        // The streams, one per tile, built and started before the timer so the first tick has
        // something to draw. Each engine delivers on its own queue, so arrival order between
        // tiles is not an order at all — which is exactly why the canvas is composed on a tick
        // rather than on arrival.
        var engines: [CaptureEngine] = []
        for (index, tile) in plan.tiles.enumerated() {
            let engine = CaptureEngine()
            engine.onFrame = { [weak self] frame in
                self?.retain(frame.pixelBuffer, at: index)
            }
            engine.onStop = { [weak self] _ in
                self?.tileStopped(index)
            }
            engines.append(engine)
            do {
                try await engine.start(.stream(filter: tile.filter, configuration: tile.configuration))
            } catch {
                // A tile that will not start leaves its rectangle black and the rest of the
                // mosaic running. It is already counted as dead, so nothing waits for it.
                mosaicLog.error("mosaic tile \(index, privacy: .public) did not start: \(String(describing: error), privacy: .public)")
                markDead(index)
            }
        }

        lock.withLock { self.engines = engines }

        startTimer(plan)
        mosaicLog.notice("mosaic started: \(plan.tiles.count, privacy: .public) tiles at \(Int(plan.canvas.width), privacy: .public)×\(Int(plan.canvas.height), privacy: .public)")
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

        let engines = lock.withLock { () -> [CaptureEngine] in
            let current = self.engines
            self.engines = []
            return current
        }
        for engine in engines {
            await engine.stop()
        }

        lock.withLock {
            self.plan = nil
            self.pool = nil
            self.held = []
            self.dirty = false
            self.deadTiles = []
        }
    }

    // MARK: - Tiles

    /// Keeps a tile's picture, in a buffer of our own.
    ///
    /// **This copy is the whole reason the type has a buffer story.** The frame's buffer belongs
    /// to a pool ScreenCaptureKit reuses the moment the callback returns, and the compositor
    /// reads it on a later tick, so taking the reference would be reading memory that has since
    /// become something else. Two planes of `420v` at tile size is a few hundred kilobytes, and
    /// the alternative is a picture made of two different moments.
    private func retain(_ buffer: CVPixelBuffer, at index: Int) {
        guard let copy = Self.copy(buffer) else { return }
        lock.withLock {
            guard index < held.count else { return }
            held[index] = HeldFrame(buffer: copy)
            dirty = true
        }
    }

    private func markDead(_ index: Int) {
        lock.withLock { _ = deadTiles.insert(index) }
    }

    /// One tile's stream ended. Only a mosaic where every tile has now stopped is a failure.
    private func tileStopped(_ index: Int) {
        markDead(index)
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
        let started = lock.withLock { held.contains { $0 != nil } }
        guard started else { return }

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
    private func draw(plan: MosaicPlan, into canvas: CVPixelBuffer) {
        let bounds = CGRect(origin: .zero, size: plan.canvas)
        let frames = lock.withLock { held }

        var image = CIImage(color: .black).cropped(to: bounds)
        for (index, tile) in plan.tiles.enumerated() {
            guard index < frames.count, let frame = frames[index] else { continue }
            let picture = CIImage(cvPixelBuffer: frame.buffer)
            image = Self.place(picture, in: tile.rect, canvas: plan.canvas).composited(over: image)
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
