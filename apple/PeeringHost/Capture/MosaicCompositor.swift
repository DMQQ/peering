import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import PeeringKit
import RemoteCore
import ScreenCaptureKit
import os

let mosaicLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// The one place that runs more than one capture at a time: ScreenCaptureKit has no filter for two displays or unrelated windows, so one stream per tile is composited into the picture the phone decodes.
/// Frames are pulled on a timer, not pushed on tile arrival: VideoEncoder needs increasing timestamps, and composing on the last tile to arrive would step back when a 60 fps window interleaved with a 15 fps one.
/// Neither buffer is ScreenCaptureKit's: its frame buffers belong to a pool reused while VideoToolbox still reads them, so each tile frame is copied on arrival and drawn from the copy.
/// The canvas comes from a CVPixelBufferPool, which will not hand back a buffer still referenced, so a tick the encoder has not finished with is skipped. Reusing one canvas buffer made frames of two pictures, which the client refused (the reason CapturePipeline/idleFramesEnabled is off).
final class MosaicCompositor: CaptureFrameSource, @unchecked Sendable {
    let lock = NSLock()

/// Serial: VideoToolbox may not be handed two frames at once.
    let queue = DispatchQueue(label: "pl.dmq.peering.capture.mosaic", qos: .userInitiated)

    /// Lets ``stop()`` tell whether it is already running on the queue, where waiting for that
    /// queue would deadlock instead of draining it.
    static let queueKey = DispatchSpecificKey<UInt8>()

/// The only object here that touches the GPU. The working colour space is named because the canvas is encoded as 420v video-range YCbCr using the matrix ScreenCaptureKit assumed per tile; the default would put an sRGB assumption under it and shift colours.
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])

    struct HeldFrame {
        let buffer: CVPixelBuffer
    }

/// An identity, not a place: built once per start(_:) and never reordered, and callbacks close over their index. Which rectangle a picture belongs in is engineForSlot's question.
    var engines: [CaptureEngine] = []
    var plan: MosaicPlan?
    var isParked = false
/// Which engine stands behind each tile of plan. A reorder changes tile order but not engine order; permuting the held frames instead leaves every engine writing into another window's slot.
    var engineForSlot: [Int] = []
    var held: [HeldFrame?] = []
    var dirty = false
    var pool: CVPixelBufferPool?
    var timer: DispatchSourceTimer?
    var frameIndex: Int64 = 0
    var deliveredCount = 0
    var skippedTicks = 0
    var deadTiles: Set<Int> = []

    var firstCanvasDeadline: DispatchTime?
    var firstCanvasAt: DispatchTime?
    var firstCanvasSent = false
/// Bumped by every start and stop so in-flight work can tell whether its state is still wanted: a stop inside a start would otherwise leave streams and a timer running forever.
    var generation = 0
/// From the frame geometry, not the colour: a capture with nothing to photograph says so in the frame attachment, and a window is allowed to be black, so a colour test would announce nothing to show over a dark editor.
    var emptyTiles: Set<Int> = []
    var _onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var _onIdle: (@Sendable (IdleSample) -> Void)?
    var _onStop: (@Sendable (CaptureError) -> Void)?
    var _onTileLost: (@Sendable (Int) -> Void)?
    var _onTileUncapturable: (@Sendable (Int) -> Void)?

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






}
