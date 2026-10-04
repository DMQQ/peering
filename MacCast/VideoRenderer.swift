import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import VideoToolbox
import os

// `nonisolated`, because this file's whole point is to run off the main actor. Without it the
// default isolation applies to file-scope globals too, and the renderer's queue cannot read it.
private nonisolated let videoLog = Logger(subsystem: "pl.dmq.peering", category: "video")

/// Decodes and displays the host's video stream.
///
/// ## Why there is no `VTDecompressionSession` here
///
/// The obvious design — build a `VTDecompressionSession`, decode into `CVPixelBuffer`s, and
/// hand those to a layer — does the same work twice. `AVSampleBufferDisplayLayer` already
/// owns a hardware decode session internally and is fed *compressed* samples, so adding a
/// second session means decompressing on the CPU side of a buffer that is about to be handed
/// to hardware anyway: extra memory, extra latency, and a second decoder to keep in sync with
/// the parameter sets. The layer's `sampleBufferRenderer` is the only object that needs to
/// know the stream exists.
///
/// ## Threading
///
/// `nonisolated`, and deliberately so. The app target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise bind every one of these
/// methods to the main actor — and enqueueing a 60 Hz video stream on the thread that is also
/// laying out SwiftUI is how a client drops frames while showing 100% CPU. Every method here
/// runs on ``queue``, and nothing touches the layer off it.
nonisolated final class VideoRenderer: @unchecked Sendable {
    /// What the UI shows about the stream. Read under the lock, so it is safe from any actor.
    struct Snapshot: Sendable, Equatable {
        var hasConfig = false
        var pixelWidth = 0
        var pixelHeight = 0
        var codec: VideoCodec = .h264
        var framesEnqueued = 0
        var bytesEnqueued: Int64 = 0
        var framesDropped = 0
        var awaitingKeyframe = true
        var lastError: String?
        /// Bumped by every config.
        var configGeneration = 0
        /// The config whose first frame has reached the live layer. The screen's cue that the
        /// picture it describes is finally the one on screen, and the one thing a hero transition
        /// waits on before it lets the frozen snapshot go. See ``onFirstFrame``.
        var readyGeneration = 0
    }

    private let queue = DispatchQueue(label: "pl.dmq.peering.video", qos: .userInteractive)
    private let lock = NSLock()

    private var renderer: AVSampleBufferVideoRenderer?
    private var formatDescription: CMVideoFormatDescription?
    /// The host's forced recovery point can beat SwiftUI to creating the display layer during a
    /// fast reconnect. Keep that one frame until ``attach(_:)`` rather than losing the only frame
    /// a decoder can start from on a still desktop.
    private var deferredKeyframe = DeferredVideoKeyframe()
    private var snapshot = Snapshot()
    /// Whether the next frame handed to the live layer will be the first of the config just
    /// applied, which is what ``onFirstFrame`` reports. There is nothing to hold it for any more:
    /// the live layer is hidden behind the frozen one for the whole of a transition (see
    /// ``VideoHostView/stillView``), so a frame reaching it while unsettled is not seen by anyone.
    private var awaitingFirstFrameOfConfig = false

    /// Called on the main actor when the first frame of the config that was last applied reaches
    /// the live layer.
    ///
    /// **The one moment that says the picture has actually changed.** A config arrives a frame or
    /// two before its own picture does (the host has to encode a keyframe and it has to cross the
    /// network), and until that frame lands the layer is still showing the stream this one
    /// replaced. This is what a hero transition waits on before it lets the frozen snapshot go.
    private var _onFirstFrame: (@MainActor @Sendable () -> Void)?
    private var _framesBelongTo: String?

    var onFirstFrame: (@MainActor @Sendable () -> Void)? {
        get { lock.withLock { _onFirstFrame } }
        set { lock.withLock { _onFirstFrame = newValue } }
    }

    /// The last frame this renderer handed to the live layer, whichever stream it belonged to.
    private var lastEnqueued: CMSampleBuffer?
    /// The most recent frame a decoder could start from, kept for the trip back from the
    /// background. The layer's contents do not survive it and neither does the decode queue, so
    /// this is the only thing left to hand it. One frame's worth of memory; see
    /// ``repaintAfterForegrounding()``.
    private var lastKeyframeSample: CMSampleBuffer?

    // MARK: - The frozen layer

    /// The renderer for the layer that is showing the picture, read from the main thread.
    ///
    /// Everything else here is confined to ``queue``; this one reference is not, because a freeze
    /// has to read the frame the layer is displaying *at the instant of the tap*, and a queue hop
    /// is enough for the animation to take its first steps against the previous snapshot — which is
    /// a tile opening onto another tile's picture, the bug this whole area exists to prevent.
    private var liveRenderer: AVSampleBufferVideoRenderer?

    /// The picture the frozen layer is holding, and the arrangement as it looked when the user
    /// left one, for the way back into it.
    ///
    /// **An image, not a run of frames, and that is the whole of why the frozen layer is honest.**
    /// It used to be given its own decoder and the keyframe-to-now run of compressed samples that
    /// decoder would need, and every fault it had came from that: the run is seconds long, so the
    /// still landed on the frame the run *started* on and rewound through the rest; a run that had
    /// not accumulated yet left the previous transition's picture on screen; and a run of one
    /// format could be handed to a decoder holding another, which draws it at a size the geometry
    /// does not know. The layer can be asked for the frame it is showing instead — one image, at
    /// its own pixel size, exact and current by construction. See ``displayedPicture()``.
    private var _stillPicture: CGImage?
    private var _mosaicSnapshot: CGImage?

    /// The picture the frozen layer is holding. Read by the view on every pass.
    var stillPicture: CGImage? { lock.withLock { _stillPicture } }

    /// One frame at the picture's own size, as the live layer has decoded it.
    func displayedPicture() -> CGImage? {
        let live = lock.withLock { liveRenderer }
        guard let live, let buffer = live.displayedPixelBuffer() else { return nil }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr else {
            videoLog.error("could not make an image of the displayed frame")
            return nil
        }
        return image
    }

    /// Freezes the frozen layer at whatever the live layer is showing right now.
    ///
    /// Called by the screen the instant it starts a hero transition — a tile opening, an
    /// arrangement coming back, a rotation — so the snapshot it is about to animate is never a
    /// frame behind the tap. Synchronous and lock-only, deliberately not `queue.async`: see
    /// ``liveRenderer``. Says whether there was a picture to freeze, so a caller can skip the
    /// animation rather than run one over a stale image.
    @discardableResult
    func freezeCurrentFrame() -> Bool {
        guard let image = displayedPicture() else { return false }
        lock.withLock { _stillPicture = image }
        return true
    }

    /// Holds a picture on the frozen layer, for a transition to animate.
    func hold(_ image: CGImage) {
        lock.withLock { _stillPicture = image }
    }

    /// The arrangement as it looked when the user left it, for the way back into it.
    ///
    /// The Mac tears the arrangement down and builds the canvas again from scratch — measured at
    /// about a second and a quarter — and this is what the frozen layer shows in the meantime,
    /// instead of a lone window in the middle of a black screen. Taken at the tap, when the frozen
    /// picture *is* the arrangement. See ``RemoteScreen/animateBackToMosaic()``.
    var mosaicSnapshot: CGImage? { lock.withLock { _mosaicSnapshot } }

    func rememberMosaicSnapshot() {
        lock.withLock { _mosaicSnapshot = _stillPicture }
    }

    /// Which source the frames arriving now belong to.
    ///
    /// Told rather than inferred: a frame is a picture with no name on it, and only the session
    /// knows what it asked the Mac for. Read by the picture trace.
    var framesBelongTo: String? {
        get { lock.withLock { _framesBelongTo } }
        set { lock.withLock { _framesBelongTo = newValue } }
    }

    // MARK: - Attachment

    /// Binds the layer this renderer draws into. Called once, from `makeUIView`.
    ///
    /// `AVSampleBufferDisplayLayer` is a `CALayer` and is not `Sendable`, so handing it to
    /// another queue is a transfer the compiler cannot check. It is marked as one deliberately
    /// rather than laundered through a box: this is the only place the layer crosses a thread
    /// boundary, nothing here touches the layer afterwards, and `sampleBufferRenderer` — the
    /// object that is actually used — is documented as safe to enqueue into from a background
    /// thread, which is what makes running the decode path off the main actor possible at all.
    @MainActor
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        // The renderer, not the layer. The layer's own `enqueue`/`flush` come from
        // `AVQueuedSampleBufferRendering`, which is deprecated on this class; the modern
        // surface is the `sampleBufferRenderer` it vends. Read here, on the main actor that
        // `attach` is documented to be called from, since the property itself is main-actor
        // isolated even though the renderer it returns is safe to use off it.
        nonisolated(unsafe) let renderer = layer.sampleBufferRenderer
        queue.async { [weak self] in
            guard let self else { return }
            self.renderer = renderer
            self.lock.withLock { self.liveRenderer = renderer }
            if let frame = self.deferredKeyframe.take(), let format = self.formatDescription {
                self.enqueue(frame, on: renderer, format: format)
            }
        }
    }

    // MARK: - Stream lifecycle

    /// Applies a new stream description and resets the decoder to match.
    ///
    /// Called once per stream and again on every source change. The parameter sets are
    /// **out of band in H.264** — they are not repeated on each keyframe — so a decoder that
    /// keeps the old format description after the host switches display decodes garbage, or
    /// nothing, until it happens to be recreated.
    func configure(_ config: VideoStreamConfig) {
        queue.async { [weak self] in
            guard let self else { return }

            guard let format = Self.makeFormatDescription(config) else {
                videoLog.error("rejected a \(config.codec.rawValue, privacy: .public) stream config: the parameter sets did not form a format description")
                // The decoder is deliberately left with *nothing* rather than with the previous
                // stream's description. Returning here without clearing it — which is what this
                // did — kept the old format description live, so frames for the new source went
                // on being wrapped in the old one: a picture the host is no longer sending,
                // decoded against parameter sets that do not describe it. `enqueue` drops
                // everything while `formatDescription` is nil, so the client shows black and
                // `lastError` explains why, which is the honest outcome for a stream that
                // cannot be decoded.
                self.renderer?.flush()
                self.formatDescription = nil
                self.lock.withLock {
                    self.snapshot.hasConfig = false
                    self.snapshot.awaitingKeyframe = true
                    self.snapshot.lastError = "Unusable parameter sets for \(config.codec.rawValue)"
                }
                return
            }

            self.formatDescription = format
            self.deferredKeyframe.reset()
            // The *queue* is discarded, because the old pictures are in the old format and a
            // decoder holding them would render one against an SPS that has been replaced.
            self.lock.withLock { self._framesBelongTo = config.sourceID }
            self.renderer?.flush(removingDisplayedImage: false)
            self.awaitingFirstFrameOfConfig = true

            self.lock.withLock {
                let generation = self.snapshot.configGeneration + 1
                self.snapshot = Snapshot()
                self.snapshot.configGeneration = generation
                self.snapshot.hasConfig = true
                self.snapshot.pixelWidth = config.pixelWidth
                self.snapshot.pixelHeight = config.pixelHeight
                self.snapshot.codec = config.codec
                self.snapshot.awaitingKeyframe = true
                self.snapshot.lastError = nil
            }
            videoLog.notice("stream configured: \(config.sourceID, privacy: .public) \(config.codec.rawValue, privacy: .public) \(config.pixelWidth)x\(config.pixelHeight) with \(config.parameterSets.count) parameter set(s)")
        }
    }

    /// Submits one compressed picture.
    func enqueue(_ frame: EncodedVideoFrame) {
        queue.async { [weak self] in
            guard let self, let format = self.formatDescription else { return }
            guard let renderer = self.renderer else {
                self.deferredKeyframe.record(frame)
                return
            }
            self.enqueue(frame, on: renderer, format: format)
        }
    }

    /// The queue-confined half of ``enqueue(_:)``, also used to replay a keyframe that arrived
    /// before SwiftUI installed the display surface.
    private func enqueue(
        _ frame: EncodedVideoFrame,
        on renderer: AVSampleBufferVideoRenderer,
        format: CMVideoFormatDescription
    ) {
        // The decoder failing is reported on the renderer, not by a return value, and it
        // is sticky: without a flush the layer refuses every later frame and the picture
        // simply never comes back.
        //
        // **This runs before the keyframe gate below, and the order is the fix rather
        // than a preference.** The flush discards every picture the decoder was holding,
        // which invalidates the stream in exactly the way a new config does — so it has
        // to re-arm the gate and then be judged by it. With the two the other way round,
        // an inter frame arriving on a failed renderer passed a gate that had already
        // been evaluated, fell through this branch, and was enqueued onto a renderer that
        // had just been emptied — and the flag set two lines above was cleared again on
        // the way out. The frame could not decode, the layer failed again, and the stream
        // stayed broken while the log said it was waiting for a keyframe.
        if renderer.status == .failed {
            videoLog.notice("renderer failed; flushing and waiting for a keyframe · \(renderer.error?.localizedDescription ?? "no error", privacy: .public)")
            renderer.flush()
            self.lock.withLock {
                self.snapshot.awaitingKeyframe = true
                self.snapshot.lastError = renderer.error?.localizedDescription
            }
        }

        // Until the first keyframe arrives there is nothing to decode against — the
        // parameter sets describe the stream, not the picture, and H.264 prediction runs
        // from the last keyframe. Feeding an inter frame here produces a decode error and
        // a flushed renderer, which costs the frames that were about to work.
        let awaitingKeyframe = self.lock.withLock { self.snapshot.awaitingKeyframe }
        if awaitingKeyframe && !frame.isKeyframe {
            self.lock.withLock { self.snapshot.framesDropped += 1 }
            return
        }

        if !renderer.isReadyForMoreMediaData {
            // Backpressure, from the renderer rather than the layer. A keyframe is the one
            // frame worth flushing for: dropping it would extend the wait for a recovery
            // point, whereas dropping an inter frame costs a single picture.
            guard frame.isKeyframe else {
                self.lock.withLock { self.snapshot.framesDropped += 1 }
                return
            }
            renderer.flush()
        }

        guard let sample = Self.makeSampleBuffer(frame, format: format) else {
            self.lock.withLock { self.snapshot.framesDropped += 1 }
            videoLog.error("makeSampleBuffer failed for a \(frame.isKeyframe ? "key" : "delta", privacy: .public) frame")
            return
        }

        // **Enqueued straight onto the live layer, whether or not anyone can see it yet.** Nothing
        // here needs to hold it back for the screen's transform any more: the live layer sits
        // hidden behind the frozen one for the whole of a transition (see
        // ``VideoHostView/stillView``), so a frame drawn on it while unsettled is not on screen at
        // all, and there is nothing left to protect it from.
        renderer.enqueue(sample)
        let firstOfConfig = awaitingFirstFrameOfConfig
        if firstOfConfig { awaitingFirstFrameOfConfig = false }
        self.lock.withLock {
            self.lastEnqueued = sample
            if frame.isKeyframe { self.lastKeyframeSample = sample }
            self.snapshot.framesEnqueued += 1
            self.snapshot.bytesEnqueued += Int64(frame.data.count)
            self.snapshot.awaitingKeyframe = false
            self.snapshot.readyGeneration = self.snapshot.configGeneration
        }
        if firstOfConfig {
            let landed = lock.withLock { _onFirstFrame }
            Task { @MainActor in landed?() }
        }
    }

    /// Puts a picture back after the app has been away, given that nothing else will.
    ///
    /// **iOS throws away what an `AVSampleBufferDisplayLayer` was showing when the app is
    /// backgrounded**, and this app has no way to notice: the host has sent nothing new, because a
    /// Mac whose screen has not changed produces no frames at all. So the app comes back to a black
    /// rectangle that stays black until something on the Mac moves — which is why a slight drag,
    /// which moves the Mac's pointer, is what brings it back, and why it reads as a frozen session
    /// rather than as a lost frame.
    ///
    /// Two cases, told apart by the layer itself. A decoder that survived the trip (the usual one,
    /// since the frames after the drag decode) needs the last picture handed to it again. A decoder
    /// that did not reports a failed renderer, and for that the way back is the documented one: a
    /// flush, and then a sync sample, which is the only kind it can start from.
    ///
    /// A stream that was reconfigured while the app was away is left alone: its own keyframe is on
    /// its way and would only be raced by this one.
    func repaintAfterForegrounding() {
        queue.async { [weak self] in
            guard let self, let renderer = self.renderer else { return }
            let (last, sync, generation) = self.lock.withLock {
                (self.lastEnqueued, self.lastKeyframeSample, self.snapshot.configGeneration)
            }

            if renderer.status == .failed {
                guard let sync, self.lock.withLock({ self.snapshot.readyGeneration }) == generation else { return }
                videoLog.notice("the display layer was left empty by the background; restarting it from the last keyframe")
                renderer.flush()
                renderer.enqueue(sync)
                self.lock.withLock { self.snapshot.awaitingKeyframe = false }
            } else if let last {
                renderer.enqueue(last)
            }
        }
    }

    /// Drops the stream: the display goes black and the next frame must be a keyframe.
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.renderer?.flush()
            self.formatDescription = nil
            self.deferredKeyframe.reset()
            self.lock.withLock {
                self.snapshot = Snapshot()
                self._framesBelongTo = nil
            }
        }
    }

    /// Ends the display attachment itself, not merely the current encoded stream.
    ///
    /// `reset()` intentionally keeps the renderer because source switches use it and the next
    /// config arrives on the same screen. A finished session is different: its SwiftUI view is
    /// leaving, so retaining the layer's renderer would retain decoder/display resources after
    /// the network session is gone.
    func detach() {
        queue.async { [weak self] in
            guard let self else { return }
            self.renderer?.flush()
            self.renderer = nil
            self.formatDescription = nil
            self.deferredKeyframe.reset()
            self.lock.withLock {
                self.snapshot = Snapshot()
                self._framesBelongTo = nil
                // The frozen picture is this stream's, and so is the session's idea of the
                // arrangement: a later session must not open on either.
                self.liveRenderer = nil
                self._stillPicture = nil
                self._mosaicSnapshot = nil
            }
        }
    }

    var currentSnapshot: Snapshot { lock.withLock { snapshot } }

    // MARK: - Format description

    /// Builds the description `CMSampleBufferCreateReady` needs, from the parameter sets the
    /// host sent out of band.
    ///
    /// `nalUnitHeaderLength: 4` is not a guess — it is what AVCC means, and it is the reason
    /// the frame payload can be handed over verbatim: both the format description and the
    /// sample data agree that each NALU is preceded by a 4-byte big-endian length.
    private static func makeFormatDescription(_ config: VideoStreamConfig) -> CMVideoFormatDescription? {
        // `NSData` rather than `Data` for the pointers: the API takes raw pointers that must
        // outlive the call, and `NSData` gives a stable `bytes` pointer plus a reference the
        // `withExtendedLifetime` below keeps alive. `Data.withUnsafeBytes` cannot be nested
        // across an array of values without the same dance, with more ways to get it wrong.
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var storage: [NSData] = []

        for set in config.parameterSets where !set.isEmpty {
            let data = set as NSData
            guard let base = data.bytes.assumingMemoryBound(to: UInt8.self) as UnsafePointer<UInt8>? else {
                continue
            }
            pointers.append(base)
            sizes.append(data.length)
            storage.append(data)
        }
        guard !pointers.isEmpty else { return nil }

        return withExtendedLifetime(storage) { () -> CMVideoFormatDescription? in
            var format: CMVideoFormatDescription?
            let status: OSStatus

            switch config.codec {
            case .h264:
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            case .hevc:
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &format
                )
            }

            guard status == noErr, let format else {
                videoLog.error("format description creation failed with OSStatus \(status, privacy: .public)")
                return nil
            }
            return format
        }
    }

    // MARK: - Sample buffers

    /// Wraps one AVCC payload in a `CMSampleBuffer` the renderer can decode.
    ///
    /// The body is in ``MacCastKit/VideoSampleBuffer``, where the three sample attachments it
    /// sets can be asserted without a session, a display layer or a Mac: getting them wrong is
    /// not a subtle failure, it is a picture that shows one frame every two seconds.
    static func makeSampleBuffer(
        _ frame: EncodedVideoFrame,
        format: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        VideoSampleBuffer.make(frame, format: format)
    }

}

/// The UIkit view whose backing layer *is* the display layer.
///
/// Overriding `layerClass` rather than adding a sublayer is what makes the video resize with
/// the view for free — UIKit keeps the backing layer's frame in step, whereas a sublayer has
/// to be repositioned on every layout pass, and lags a frame behind during rotation.
final class VideoDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        if let displayLayer {
            displayLayer.videoGravity = .resizeAspect
            displayLayer.backgroundColor = UIColor.black.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Hosts ``VideoDisplayView`` in SwiftUI and hands its layer to the renderer.
struct VideoLayerView: UIViewRepresentable {
    let renderer: VideoRenderer
    /// The picture's own size, as this app believes it, for the trace below and nothing else.
    ///
    /// The layer has its own answer: it is the size of the screen and it fits whatever frame it holds
    /// into itself. The two agreeing is the whole of what keeps the picture where the app draws
    /// everything else, and the trace is how they are compared.
    var pictureSize: CGSize = .zero
    /// The scale the picture is drawn at, applied about its centre.
    var zoom: CGFloat = 1
    /// How far the picture is moved from the centre of its frame, in points.
    var pan: CGSize = .zero

    /// The scale and offset the outgoing picture was drawn at, and whether it is the one showing.
    ///
    /// The still carries the transform the picture had *before* the change, because it is that
    /// picture; the live layer takes the new one and fades in over it. Both are the same rectangle
    /// on screen — that is what the movement between two pictures is for — so what the user
    /// watches is the picture sharpening rather than either of them jumping.
    var stillZoom: CGFloat = 1
    var stillPan: CGSize = .zero
    var showsStill = false

    /// The picture the frozen layer is holding, which only the renderer can take. See
    /// ``VideoRenderer/stillPicture``.
    var stillPicture: CGImage?

    /// Drawn under the frozen layer while a window shrinks back into the mosaic, so the other tiles
    /// are there from the first frame instead of appearing when the movement ends.
    var backdropPicture: CGImage?
    var backdropZoom: CGFloat = 1

    /// The live layer's own bookkeeping about which of the two pictures it is showing. See
    /// ``VideoHostView/stillContentView``.
    final class Coordinator {
        var showsStill = false
        /// The image the frozen layer is holding, so a pass that changes nothing else does not
        /// re-rasterise it.
        var stillPicture: CGImage?
        var backdropPicture: CGImage?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        if let layer = view.displayView.displayLayer {
            renderer.attach(layer)
            // The display view rather than the container, so PiP mirrors the layer that is
            // actually holding the picture — the container only ever carries a transform.
            SessionPiP.shared.attach(view.displayView)
        }
        // **The still is deliberately not offered to PiP.** It holds one frame of the session
        // before this one; a floating window showing it would be a picture that stopped.
        return view
    }

    func updateUIView(_ view: VideoHostView, context: Context) {
        // The picture's placement, applied as a layer transform with Core Animation's implicit
        // animation switched off.
        //
        // Both halves of that are the fix for a pan that trailed the finger. The offset used to
        // be applied by SwiftUI on this representable, which moves the hosted view through
        // UIKit's layout — and a view whose position changes outside a disabled-actions
        // transaction gets Core Animation's implicit quarter-second animation, which is exactly
        // a picture that lags behind the thumb and catches up after it stops. A transform also
        // moves what is already drawn instead of asking the view to lay out again at a new
        // origin, so the video layer is never resized and never re-fits the frame it is holding.
        //
        // The content view rather than the hosted view, which SwiftUI resizes out from under any
        // transform put on it — see ``VideoHostView/contentView``. And rather than the display
        // view, whose layer is what PiP mirrors: a transform on that one would be a transform on
        // the floating window too.
        let target = CGAffineTransform(translationX: pan.width, y: pan.height)
            .scaledBy(x: zoom, y: zoom)
        let stillTarget = CGAffineTransform(translationX: stillPan.width, y: stillPan.height)
            .scaledBy(x: stillZoom, y: stillZoom)

        // **The hand-over, and it is one commit or it is nothing.** Four things have to happen
        // together: the still takes the picture being frozen, the live layer takes the arriving
        // picture's transform, the still takes the outgoing one, and the live layer is hidden.
        // Written in one disabled-actions transaction, the render server applies all four in the
        // same frame, so there is no frame in which the outgoing picture is drawn at the incoming
        // picture's scale, and none in which the still is shown before it holds a picture. Hiding
        // the live layer cannot be seen either: at this instant the two hold the same frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if stillPicture !== context.coordinator.stillPicture {
            context.coordinator.stillPicture = stillPicture
            view.stillView.layer.contents = stillPicture
        }
        view.contentView.transform = target
        view.stillContentView.transform = stillTarget
        if backdropPicture !== context.coordinator.backdropPicture {
            context.coordinator.backdropPicture = backdropPicture
            view.backdropView.layer.contents = backdropPicture
        }
        view.backdropContentView.transform = CGAffineTransform(scaleX: backdropZoom, y: backdropZoom)
        view.backdropContentView.isHidden = backdropPicture == nil || !showsStill
        if showsStill {
            view.stillContentView.alpha = 1
            view.contentView.alpha = 0
        }
        CATransaction.commit()

        // The way back out is the only part that is watched, so it is the only part that is
        // animated: a hard cut here is a source change, and this is what turns it into the picture
        // settling. Instant on the way in, because nothing is visible at that moment anyway.
        if showsStill != context.coordinator.showsStill {
            context.coordinator.showsStill = showsStill
            if !showsStill {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.18)
                CATransaction.setAnimationTimingFunction(
                    CAMediaTimingFunction(name: .easeInEaseOut)
                )
                view.stillContentView.alpha = 0
                view.contentView.alpha = 1
                CATransaction.commit()
            }
        }

    }
}

/// A plain container, so the picture can be moved without moving the layer PiP mirrors.
final class VideoHostView: UIView {
    /// Carries the zoom and the pan. Never touched by SwiftUI, which is the whole point of it.
    ///
    /// A subview of its own rather than the hosted view itself, and this is not structure for its
    /// own sake — it is the difference between a pinch that resizes the picture and one that only
    /// moves a number. SwiftUI sizes a representable by setting its **frame**, and UIKit answers a
    /// frame set on a transformed view by shrinking `bounds` until `bounds × transform` is the
    /// frame again. So the hosted view rendered at exactly the size it was given whatever the
    /// transform said, and every pinch was undone by the next layout pass. Measured in the
    /// diagnostics, halfway through one pinch: `932×430` at 100% and `589×272` at 171% — the
    /// picture shrinking under the transform that was meant to be growing it.
    ///
    /// A translation is not compensated the same way, which is why panning looked like it worked
    /// whenever there was panning to do — one axis of one gesture, and the reason this survived
    /// every attempt to catch it by reading.
    let contentView = UIView()

    let displayView = VideoDisplayView()

    /// The picture being replaced, still, under the live one.
    ///
    /// **A change of source cannot be made atomic from here, so it is made invisible instead.**
    /// The live layer swaps its own contents on the render server's clock, and the transform that
    /// scales them is written by the main thread, so around every source change there is a moment
    /// where one of the two is showing the wrong pair: the old picture at the new scale, or the
    /// new picture at the old one. Both were tried and both were visible. Held here, the outgoing
    /// picture can be shown at the outgoing scale while the live layer changes underneath it, and
    /// then the two are cross-faded — which is the only transition a video layer allows, because
    /// the pair that must never be seen never has to be drawn.
    ///
    /// **It is an image, not a second decoder.** The picture it holds is taken from the live layer
    /// at the instant of a freeze and put in this view's `contents`, fitted the same way the live
    /// layer fits its own frames. A decoder here was the previous design and it was wrong for the
    /// job: a decoder needs the references of the frame it is asked to show, which means a run of
    /// seconds of compressed samples, which means the still shows that run's *first* frame until it
    /// catches up. An image has no references to be missing and nothing to catch up on. See
    /// ``VideoRenderer/displayedPicture()``.
    let stillContentView = UIView()
    let stillView: UIView = {
        let view = UIView()
        // The same fit the display layer uses, so a rect computed from a pixel size lands on the
        // picture exactly as it does on the live one.
        view.layer.contentsGravity = .resizeAspect
        // Clear rather than black: shrunk into a tile, black bars would cover the tiles beside it.
        // The host view's own black shows through when nothing is behind.
        return view
    }()
    let backdropContentView = UIView()
    let backdropView: UIView = {
        let view = UIView()
        view.layer.contentsGravity = .resizeAspect
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // The picture is scaled inside this view, and the scaled content view paints outside the
        // bounds unless it is clipped: a sublayer is not clipped by its parent by default, and
        // this one is a sibling of the chrome's layers.
        clipsToBounds = true

        // Under the live one, and both sized the same way. The still is what is left on screen
        // when the live layer is faded out, so it has to cover the same ground.
        for (container, display) in [(backdropContentView, backdropView), (stillContentView, stillView), (contentView, displayView)] {
            container.frame = bounds
            addSubview(container)
            display.frame = container.bounds
            display.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(display)
        }
        stillContentView.alpha = 0
        backdropContentView.isHidden = true
    }

    /// Sized through `bounds` and `center`, never through `frame`, which is why this is here
    /// instead of an `autoresizingMask` on the content view.
    ///
    /// UIKit answers a *frame* set on a transformed view by shrinking its bounds until
    /// `bounds × transform` is that frame again — the compensation that made every zoom
    /// invisible, and an autoresizing subview re-runs it on every geometry change. Bounds and
    /// centre leave the transform alone, so a rotation or the keyboard coming up cannot undo the
    /// picture's scale behind the user's back.
    override func layoutSubviews() {
        super.layoutSubviews()
        for container in [backdropContentView, stillContentView, contentView] {
            container.bounds = CGRect(origin: .zero, size: bounds.size)
            container.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }


    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The picture in a floating window, over whatever else is on screen.
///
/// Picture in Picture rather than a view of our own: iOS draws it, it survives the app being
/// backgrounded *because* it is what is keeping the app alive, and it is the only way to have
/// something float over another app at all. The content source is the same
/// `AVSampleBufferDisplayLayer` the in-app screen draws into, so there is no second decode and
/// nothing to keep in step — the frames go to one layer and both surfaces show it.
///
/// **It is watch-only.** The floating window is not the app's view hierarchy, so touches in it
/// go to iOS's own controls and never reach the Mac. What is worth watching through it is
/// something left running — a build, a render, a long download — which is a real thing to want
/// and not the same thing as driving the Mac from a floating window.
@MainActor
@Observable
final class SessionPiP: NSObject {
    static let shared = SessionPiP()

    /// Whether the user wants iOS to float the picture on its own when the app goes away.
    ///
    /// Our own switch, because the system's is buried. Settings → General → Picture in
    /// Picture → "Start PiP Automatically" is two levels into Settings and reads as a setting
    /// for watching video rather than for driving a Mac, which is why it went unfound for most
    /// of a day's debugging.
    ///
    /// It is a preference *and* a hint. Turning it off does not stop the button, and turning it
    /// on cannot make iOS start something the system-wide setting forbids: both have to allow
    /// it, and this one only speaks for the app.
    ///
    /// **Half of the answer.** This is the switch, which is drawn on every plan so that a
    /// subscriber can see what they are buying and an owner can see what they have. Whether the
    /// arming it asks for is allowed to happen is ``isOnPlan``, and the two are put together in
    /// ``applyAutoStart()``.
    var autoStart =
        UserDefaults.standard.object(forKey: PreferenceKeys.pipAutoStart) as? Bool ?? true {
        didSet { applyAutoStart() }
    }

    /// Whether the plan the user is on includes Picture in Picture.
    ///
    /// **Pushed in rather than read here.** This object owns no store, deliberately: it is the
    /// singleton the session's view hierarchy talks to, and a plan read inside it would be a
    /// second copy of an entitlement nothing keeps in step with the first. The app tells it
    /// instead, from ``SessionModel/applyPictureInPicturePlan()``, at every moment the answer
    /// can change.
    ///
    /// **False until something says otherwise, and that is the direction to fail in.** A push
    /// that never arrives costs a paying subscriber the automatic start on a picture they can
    /// still float by hand; the other default would hand a paid feature to somebody who has not
    /// bought it. The automatic start is also the one plan-dependent thing in this app that
    /// fires without a control being touched: leaving the app is a gesture rather than a tap,
    /// so there is no later moment at which a gate could ask.
    var isOnPlan = false {
        didSet { applyAutoStart() }
    }

    /// The two halves together, written onto the controller that is actually armed.
    ///
    /// Called from both properties above and from ``attach(_:)``, because the controller is
    /// replaced for every session and either input can change while one is on screen. What iOS
    /// reads is this combination and never the preference on its own: a switch that is on over
    /// a plan that does not include it is not permission.
    private func applyAutoStart() {
        controller?.canStartPictureInPictureAutomaticallyFromInline = autoStart && isOnPlan
    }

    /// What the last attempt did, for the screen.
    ///
    /// Recorded on success as well as refusal, because the question here is as often "did
    /// anything even try" as "why not" — `enteringBackground` may never reach `start`, and
    /// silence is the same either way.
    private(set) var lastAttempt: String?

    /// Why the last attempt refused, for the screen.
    ///
    /// PiP declines without telling anyone which of its prerequisites was missing, and the
    /// device's log needs a USB connection to read — so the answer goes where the person
    /// asking the question already is.
    private(set) var lastRefusal: String?

    private var controller: AVPictureInPictureController?

    /// The view whose layer is being mirrored, held weakly.
    ///
    /// Weak because SwiftUI owns it and PiP does not: `RemoteScreen` is rebuilt for every
    /// session, and the view goes with it. Holding it strongly would keep a torn-down view —
    /// and its layer — alive behind a controller that can no longer do anything with it.
    private weak var host: VideoDisplayView?

    private override init() { super.init() }

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Where the app was when it asked, in a word.
    ///
    /// The single fact that separates "Picture in Picture is broken" from "Picture in Picture
    /// was asked at a moment it does not answer". `applicationState` rather than the scene
    /// phase because it is what UIKit itself reads to decide whether a foreground app is
    /// asking, and it is the one that keeps answering once the app is on its way out.
    private static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: return "foreground"
        case .inactive: return String(localized: "on its way out")
        case .background: return "background"
        @unknown default: return String(localized: "in an unknown state")
        }
    }

    /// AVKit's own domain, and its code for the one failure it explains itself — see the
    /// delegate's `failedToStart…`, which is the only place either is read.
    private static let pictureInPictureErrorDomain = "AVKitErrorDomain"
    private static let sceneNotForegroundCode = -1001

    /// Binds the view PiP should mirror. Called from `makeUIView`, for every session.
    ///
    /// Rebinding rather than binding once, which is what this used to do and what broke it. The
    /// controller was built on the first session's layer and the `controller == nil` guard then
    /// kept it for the life of the process — so every session after the first handed PiP a
    /// layer that had already been torn down with the screen it belonged to, and every start
    /// against it was refused. Which session it was made it look intermittent, and the refusal
    /// names nothing, so it read as "PiP does not work".
    func attach(_ view: VideoDisplayView) {
        guard Self.isSupported, host !== view else { return }

        // The screen being replaced may be the one PiP is floating. Stopped first, because a
        // window left up showing a layer nobody owns is worse than no window: it is the last
        // session's picture, frozen, in a frame the user has to dismiss by hand.
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller = nil
        host = view

        guard let layer = view.displayLayer else { return }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        // Takes the fast-forward, the forward-skip and the scrubber out of the window's
        // controls, which is what they should be: this is a live picture of a Mac, and there is
        // nothing ahead of it to skip to. "Certain user operations" is the header's own
        // wording, and the three it names are the three listed here.
        //
        // The play/pause and the backward-skip are not among them and have no equivalent
        // switch. The pause is answered by the delegate's `IsPlaybackPaused` — which reports
        // false, because a frame held back here is a dropped frame rather than a pause — and
        // the backward-skip completes immediately, so both are inert rather than absent.
        controller.requiresLinearPlayback = true
        // Set for the failure callback: without a delegate, a refusal to start is silent.
        controller.delegate = self
        self.controller = controller
        // **The whole point of it**: going to another app floats the picture rather than ending
        // the session. Starting it by hand would mean the gesture that matters, leaving the app,
        // is the one that does not trigger it. Last rather than first because it is the call
        // that writes to the controller, and it writes the switch and the plan together rather
        // than the switch alone.
        applyAutoStart()
    }

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// Called as the app leaves the screen.
    ///
    /// The one place the automatic case can be observed at all: whether it asked, and what
    /// came back. Recorded either way, because "it never tried" and "it tried and was refused"
    /// are the two halves this has to be told apart from, and both are silence on screen.
    func backgrounding(sessionIsUp: Bool) {
        guard sessionIsUp else {
            lastAttempt = String(localized: "app left screen with no session up")
            return
        }
        start()
    }

    /// Starts it now rather than on the way out of the app.
    ///
    /// The automatic start is the feature; this exists to be able to try it without leaving,
    /// and — more usefully — to be able to say *why* it will not start, which is otherwise
    /// silence. PiP depends on several things being true at once and refuses without telling
    /// anyone which one was not.
    func start() {
        guard PictureInPictureAccess.canStart(isOnPlan: isOnPlan) else {
            lastRefusal = String(localized: "Picture in Picture is part of \(PlanCapability.pictureInPicture.minimumPlan.name).")
            lastAttempt = String(localized: "not included in plan")
            videoLog.notice("Picture in Picture refused because the current plan does not include it")
            return
        }
        guard let controller else {
            lastRefusal = String(localized: "No picture yet. PiP mirrors the video layer, so a session has to be running.")
            lastAttempt = String(localized: "no layer")
            videoLog.error("Picture in Picture has no layer to mirror yet")
            return
        }
        // Answered before anything is asked about the layer, because a *running* PiP is the one
        // state in which leaving the screen is the whole point: iOS lifts the layer out of the
        // view hierarchy to draw it in its own window, so the window checks below would read a
        // window that is up and working as one that is not there.
        if controller.isPictureInPictureActive {
            lastRefusal = nil
            lastAttempt = String(localized: "already active")
            return
        }
        // Checked before `isPictureInPicturePossible`, not instead of it, because this is the
        // one prerequisite the controller does *not* re-evaluate: it went on reporting that a
        // start was possible for a layer that had been torn down with the screen it belonged
        // to. A layer not in a window is a start that cannot work, whatever the controller
        // says, and saying so here names it.
        guard let host, host.window != nil else {
            lastRefusal = """
                The video is not on screen any more. PiP lifts the layer out of the view it is \
                drawn in, so it has to be in one when it is asked. Asked while \(Self.appState).
                """
            lastAttempt = String(localized: "no screen to lift the layer out of")
            videoLog.error("Picture in Picture has no window: \(self.lastRefusal ?? "", privacy: .public)")
            return
        }
        guard controller.isPictureInPicturePossible else {
            // Every prerequisite in one line, because PiP refuses without saying which was
            // missing and the three fail for entirely different reasons: the layer has to be
            // in a visible view, the audio session has to be active, and the video has to be
            // actually rendering rather than merely configured.
            let audio = AVAudioSession.sharedInstance()
            lastRefusal = """
                Not supported here. Supported \(Self.isSupported ? "yes" : "no"), \
                audio category \(audio.category.rawValue), running \(!audio.isOtherAudioPlaying), \
                asked while \(Self.appState)
                """
            lastAttempt = String(localized: "not possible")
            videoLog.error("Picture in Picture is not possible: \(self.lastRefusal ?? "", privacy: .public)")
            return
        }
        lastRefusal = nil
        // Where it was asked is part of the record, not decoration. A start that comes back
        // refused names nothing, and the only difference between a start that should have
        // worked and one that never could is where the app was when it was made.
        lastAttempt = String(localized: "asked while \(Self.appState)")
        videoLog.notice("Asking for Picture in Picture while \(Self.appState, privacy: .public)")
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    /// Stops the floating window and releases the content source tied to the departing video
    /// layer. A later `attach` builds a controller for the next session's layer.
    func detach() {
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller = nil
        host = nil
    }
}

extension SessionPiP: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        videoLog.notice("Picture in Picture started")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        videoLog.notice("Picture in Picture stopped")
    }

    /// The app's session screen never left the hierarchy; PiP only lifted its video layer into a
    /// system window. Tell AVKit that the interface is ready when the user taps the PiP return
    /// control, otherwise AVKit has no completed restoration to hand back to the app.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // SwiftUI kept the session screen alive while the layer floated, so there is no route to
        // rebuild and no asynchronous presentation to await. AVKit is asking whether restoration
        // succeeded, not whether the layer has already been reattached on this exact run-loop turn.
        completionHandler(true)
    }

    /// The one that matters. PiP refuses for a long list of reasons and this is the only place
    /// any of them is ever named.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        let failure = error as NSError

        // The one refusal AVKit spells out, and it says more than it appears to.
        //
        // `AVKitErrorDomain` `-1001` — "Failed to start picture in picture." — is built at
        // exactly one place in AVKit, behind exactly one test: the content source's scene is not
        // `UISceneActivationStateForegroundActive`. It is not a general "something went wrong";
        // it is this, every time. So the sentence is worth replacing with its meaning rather
        // than relaying, because relaying it is what makes it read as "Picture in Picture is
        // broken" — and it is the expected answer to the one call this app makes on the way out,
        // since `enteringBackground` runs after the app has already left the foreground.
        //
        // Worth knowing for the other direction too: nothing else reports through here. A layer
        // with no window, a missing audio session, a controller pointed at a screen that has
        // been torn down — all of those fail in silence or through a backend error with a
        // different domain. A `-1001` is a timing fact and never a wiring one.
        if failure.domain == Self.pictureInPictureErrorDomain,
           failure.code == Self.sceneNotForegroundCode {
            lastRefusal = """
                iOS only starts Picture in Picture for an app that is on screen, and this ask \
                was made while \(Self.appState). Asking on the way out cannot work. Arriving \
                unasked is the automatic start's job, and that needs "Start PiP Automatically" \
                on under Settings → General → Picture in Picture.
                """
        } else {
            lastRefusal = """
                Could not start: \(error.localizedDescription) \
                (\(failure.domain) \(failure.code)), asked while \(Self.appState)
                """
        }

        lastAttempt = "failed"
        videoLog.error("""
            Picture in Picture could not start: \(error.localizedDescription, privacy: .public) \
            \(failure.domain, privacy: .public) \(failure.code, privacy: .public), \
            asked while \(Self.appState, privacy: .public), \
            reason \(failure.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? "none given", privacy: .public)
            """)
    }
}

extension SessionPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
    /// Live content, with an infinite duration.
    ///
    /// The header names two signals and this is the one that works:
    ///
    /// - *"a duration of kCMTimeInfinity to indicate live content"* — what this returns.
    /// - *"When there is no content to play, they should return kCMTimeRangeInvalid"* — tried,
    ///   and it does not mean what it says. iOS renders `invalid` as a **loading spinner** over
    ///   a frozen picture, reading it as "content is on its way" rather than "there is none".
    ///   The documentation's own wording invites exactly that reading and the behaviour
    ///   contradicts it.
    ///
    /// So the transport controls stay. What removes some of them is
    /// `requiresLinearPlayback`, and what would remove all of them is a different content
    /// source entirely — see ``SessionPiP``.
    func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    /// Never paused. The pause control would otherwise appear, and there is nothing here for it
    /// to mean — the frames arrive when the Mac sends them, and holding them back is a dropped
    /// frame rather than a pause.
    func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
