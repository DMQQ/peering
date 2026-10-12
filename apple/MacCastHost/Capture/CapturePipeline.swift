import CoreMedia
import CoreVideo
import Foundation
import MacCastKit
import RemoteCore
import ScreenCaptureKit
import os

let pipelineLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Capture and encode as one unit the session drives, owning the rules that tie them together: a resize past the encoder's size rebuilds it, and a rebuilt encoder owes a keyframe.
/// Runs on the serial capture queue, which is what makes the encoder swap safe without a lock.
final class CapturePipeline: @unchecked Sendable {
    /// Two cases rather than an optional resolver: the synthetic path must be unable to reach ScreenCaptureKit, which fails or kills the process without Screen Recording.
    enum Backend {
        /// A mosaic is a capture source like any other, selected with the same command; selecting one of its tiles is an ordinary source switch.
        case capture(resolver: CaptureSourceResolver, engine: CaptureEngine, compositor: MosaicCompositor)
        case synthetic(engine: SyntheticCaptureEngine)
    }

    let backend: Backend
    /// What the host is set to stream. The codec a stream really uses can be H.264 instead, for a client that cannot decode this one.
    let preferredCodec: VideoCodec
    private let codecLock = NSLock()
    private var activeCodec: VideoCodec

    var codec: VideoCodec { codecLock.withLock { activeCodec } }

    /// Takes effect when the next stream starts.
    func useCodec(_ codec: VideoCodec) {
        codecLock.withLock { activeCodec = codec }
    }
    /// Nil on synthetic pipelines (no screen) and for callers with no preferences store. See ``CursorOverlay``.
    let overlay: CursorOverlay?
    let lock = NSLock()

    var encoder: VideoEncoder?
    var source: CaptureSource?
    /// Held here, not only in the encoder: the encoder can be replaced mid-flight, and a request that dies with the old session leaves the client on a picture that never resolves.
    var awaitsKeyframe = false
    /// Guarded by ``lock``.
    var failureLogGate = FailureLogGate()

    var _onFrame: (@Sendable (EncodedFrame, CaptureSource) -> Void)?
    var _onGeometry: (@Sendable (FrameGeometry) -> Void)?
    var _onFailure: (@Sendable (CaptureError) -> Void)?
    var _onAudio: (@Sendable (CMSampleBuffer) -> Void)?

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
    var runningEngine: (any CaptureFrameSource)?

    /// Read from the recorded source rather than the engine, to avoid a lock on the frame path.
    var isMosaic: Bool { lock.withLock { source }?.isMosaic ?? false }

    /// The arrangement whose captures keep running behind a window on screen. Cannot be derived from ``runningEngine``. See ``releaseRunningSource(keepingMosaicFor:)``.
    var parkedMosaic: MosaicCompositor?

    var engine: any CaptureFrameSource {
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
        self.preferredCodec = codec
        self.activeCodec = codec
        self.overlay = overlay
    }

    /// Generates its own frames so the real pipeline runs where Screen Recording is not granted. Nothing here touches ScreenCaptureKit; the source passed to `start` is only recorded.
    init(syntheticPixelSize: CGSize, frameRate: Int = 60, codec: VideoCodec = .h264) {
        self.backend = .synthetic(
            engine: SyntheticCaptureEngine(pixelSize: syntheticPixelSize, frameRate: frameRate)
        )
        self.preferredCodec = codec
        self.activeCodec = codec
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

    var thumbnailWatch: Task<Void, Never>?

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



}
