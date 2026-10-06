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

// `nonisolated`: default isolation applies to file-scope globals too, and the renderer's queue could not read it.
private nonisolated let videoLog = Logger(subsystem: "pl.dmq.peering", category: "video")

/// Decodes and displays the host's video stream. No `VTDecompressionSession`: `AVSampleBufferDisplayLayer` already owns a hardware decoder fed compressed samples, so a second one would only add memory and latency.
/// `nonisolated` on purpose: the app's MainActor default would put 60 Hz enqueueing on the thread that lays out SwiftUI and drop frames. Everything runs on ``queue``.
nonisolated final class VideoRenderer: @unchecked Sendable {
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
        var configGeneration = 0
        /// The config whose first frame has reached the live layer; a hero transition waits on it before releasing the frozen snapshot. See ``onFirstFrame``.
        var readyGeneration = 0
    }

    private let queue = DispatchQueue(label: "pl.dmq.peering.video", qos: .userInteractive)
    private let lock = NSLock()

    private var renderer: AVSampleBufferVideoRenderer?
    private var formatDescription: CMVideoFormatDescription?
    /// A forced recovery point can beat SwiftUI to creating the display layer on a fast reconnect; kept until ``attach(_:)`` since it is the only frame a decoder can start from on a still desktop.
    private var deferredKeyframe = DeferredVideoKeyframe()
    private var snapshot = Snapshot()
    /// Whether the next frame to the live layer is the first of the config just applied, which ``onFirstFrame`` reports.
    private var awaitingFirstFrameOfConfig = false

    /// Called on the main actor when the first frame of the last applied config reaches the live layer. A config arrives before its own picture (keyframe encode plus network), and until then the layer still shows the old stream.
    private var _onFirstFrame: (@MainActor @Sendable () -> Void)?
    private var _framesBelongTo: String?

    var onFirstFrame: (@MainActor @Sendable () -> Void)? {
        get { lock.withLock { _onFirstFrame } }
        set { lock.withLock { _onFirstFrame = newValue } }
    }

    private var lastEnqueued: CMSampleBuffer?
    /// The most recent frame a decoder could start from, kept for the trip back from the background, which loses the layer's contents and the decode queue. See ``repaintAfterForegrounding()``.
    private var lastKeyframeSample: CMSampleBuffer?

    // MARK: - The frozen layer

    /// Read from the main thread, unlike everything else here (confined to ``queue``): a freeze must read the frame at the instant of the tap, and a queue hop lets the animation start against the previous snapshot.
    private var liveRenderer: AVSampleBufferVideoRenderer?

    /// An image, not a run of frames: a separate decoder fed keyframe-to-now samples rewound through the run, showed stale pictures and mixed formats. The layer is asked for the frame it is showing instead. See ``displayedPicture()``.
    private var _stillPicture: CGImage?
    private var _mosaicSnapshot: CGImage?

    var stillPicture: CGImage? { lock.withLock { _stillPicture } }

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

    /// Synchronous and lock-only, not `queue.async` (see ``liveRenderer``), so the snapshot is never a frame behind the tap. Returns whether there was a picture, so callers can skip the animation.
    @discardableResult
    func freezeCurrentFrame() -> Bool {
        guard let image = displayedPicture() else { return false }
        lock.withLock { _stillPicture = image }
        return true
    }

    func hold(_ image: CGImage) {
        lock.withLock { _stillPicture = image }
    }

    /// The Mac rebuilds the canvas from scratch on leaving an arrangement (about 1.25 s); this is what the frozen layer shows meanwhile. See ``RemoteScreen/animateBackToMosaic()``.
    var mosaicSnapshot: CGImage? { lock.withLock { _mosaicSnapshot } }

    func rememberMosaicSnapshot() {
        lock.withLock { _mosaicSnapshot = _stillPicture }
    }

    /// Told rather than inferred: a frame carries no source name. Read by the picture trace.
    var framesBelongTo: String? {
        get { lock.withLock { _framesBelongTo } }
        set { lock.withLock { _framesBelongTo = newValue } }
    }

    // MARK: - Attachment

    /// `AVSampleBufferDisplayLayer` is not Sendable; it is marked as a transfer here, its only thread crossing, because `sampleBufferRenderer` is safe to enqueue into from a background thread.
    @MainActor
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        // The renderer, not the layer: the layer's own `enqueue`/`flush` are deprecated. Read on the main actor since the property is main-actor isolated.
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

    /// H.264 parameter sets are out of band, so a decoder keeping the old format description after a source switch decodes garbage.
    func configure(_ config: VideoStreamConfig) {
        queue.async { [weak self] in
            guard let self else { return }

            guard let format = Self.makeFormatDescription(config) else {
                videoLog.error("rejected a \(config.codec.rawValue, privacy: .public) stream config: the parameter sets did not form a format description")
                // Cleared rather than left on the previous stream's description, which wrapped new frames in old parameter sets. `enqueue` drops everything while `formatDescription` is nil, so the client shows black and `lastError` says why.
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
            // The queue is discarded: old pictures are in the old format and would render against a replaced SPS.
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

    /// Queue-confined half of ``enqueue(_:)``, also replays a keyframe that arrived before the display surface existed.
    private func enqueue(
        _ frame: EncodedVideoFrame,
        on renderer: AVSampleBufferVideoRenderer,
        format: CMVideoFormatDescription
    ) {
        // A failed renderer is sticky: without a flush the layer refuses every later frame.
        // This runs before the keyframe gate on purpose: the flush invalidates the stream like a new config, so it must re-arm the gate and then be judged by it. In the other order an inter frame passed the gate, hit a just-emptied renderer, and the stream stayed broken.
        if renderer.status == .failed {
            videoLog.notice("renderer failed; flushing and waiting for a keyframe · \(renderer.error?.localizedDescription ?? "no error", privacy: .public)")
            renderer.flush()
            self.lock.withLock {
                self.snapshot.awaitingKeyframe = true
                self.snapshot.lastError = renderer.error?.localizedDescription
            }
        }

        // No keyframe yet means nothing to decode against: an inter frame here gives a decode error and a flush that costs frames that would have worked.
        let awaitingKeyframe = self.lock.withLock { self.snapshot.awaitingKeyframe }
        if awaitingKeyframe && !frame.isKeyframe {
            self.lock.withLock { self.snapshot.framesDropped += 1 }
            return
        }

        if !renderer.isReadyForMoreMediaData {
            // Backpressure: a keyframe is worth flushing for, dropping it extends the wait for a recovery point; an inter frame costs one picture.
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

        // Enqueued straight onto the live layer: it is hidden behind the frozen one for a whole transition (see ``VideoHostView/stillView``), so an unsettled frame is never seen.
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

    /// iOS discards what the layer was showing when backgrounded, and a Mac with a still screen sends nothing, so the app returns to black until something moves (it reads as a frozen session).
    /// A surviving decoder needs the last picture handed again; a failed renderer needs a flush then a sync sample. A stream reconfigured while away is left alone: its own keyframe is coming.
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

    /// Unlike `reset()`, which keeps the renderer for source switches, this ends the attachment so a finished session does not retain decoder resources.
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
                // The frozen picture and arrangement belong to this stream; a later session must not open on either.
                self.liveRenderer = nil
                self._stillPicture = nil
                self._mosaicSnapshot = nil
            }
        }
    }

    var currentSnapshot: Snapshot { lock.withLock { snapshot } }

    // MARK: - Format description

    /// `nalUnitHeaderLength: 4` is AVCC: the frame payload is handed over verbatim because both sides agree each NALU has a 4-byte big-endian length.
    private static func makeFormatDescription(_ config: VideoStreamConfig) -> CMVideoFormatDescription? {
        // `NSData` for a stable `bytes` pointer that `withExtendedLifetime` keeps alive; nested `Data.withUnsafeBytes` over an array is error-prone.
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

    /// Body lives in ``MacCastKit/VideoSampleBuffer`` so its three attachments can be tested; wrong ones show one frame every two seconds.
    static func makeSampleBuffer(
        _ frame: EncodedVideoFrame,
        format: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        VideoSampleBuffer.make(frame, format: format)
    }

}

/// Overriding `layerClass` makes the video resize with the view; a sublayer lags a frame behind during rotation.
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

struct VideoLayerView: UIViewRepresentable {
    let renderer: VideoRenderer
    /// The picture's size as this app believes it, for the trace only; the layer fits frames its own way and the trace compares the two.
    var pictureSize: CGSize = .zero
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    /// The still carries the transform the picture had before the change; the live layer takes the new one and fades in over it, so the same rectangle sharpens rather than jumps.
    var stillZoom: CGFloat = 1
    var stillPan: CGSize = .zero
    var showsStill = false

    var stillPicture: CGImage?

    var backdropPicture: CGImage?
    var backdropZoom: CGFloat = 1

    final class Coordinator {
        var showsStill = false
        var stillPicture: CGImage?
        var backdropPicture: CGImage?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        if let layer = view.displayView.displayLayer {
            renderer.attach(layer)
            // The display view, not the container, so PiP mirrors the layer actually holding the picture.
            SessionPiP.shared.attach(view.displayView)
        }
        // The still is not offered to PiP: it holds a frame from the previous session.
        return view
    }

    func updateUIView(_ view: VideoHostView, context: Context) {
        // Placement is a layer transform with implicit animation off: SwiftUI-applied offsets went through UIKit layout and got Core Animation's quarter-second implicit animation, so a pan trailed the finger.
        // Applied to the content view, not the hosted view (SwiftUI resizes it under any transform, see ``VideoHostView/contentView``) and not the display view (PiP mirrors its layer).
        let target = CGAffineTransform(translationX: pan.width, y: pan.height)
            .scaledBy(x: zoom, y: zoom)
        let stillTarget = CGAffineTransform(translationX: stillPan.width, y: stillPan.height)
            .scaledBy(x: stillZoom, y: stillZoom)

        // The hand-over is one commit: still takes the frozen picture, live layer takes the arriving transform, still takes the outgoing one, live is hidden, all in one disabled-actions transaction so no frame shows a mismatched pair.
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

        // Only the way back out is animated (a hard cut is a source change; this makes it settle). Instant on the way in.
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
    /// Carries the zoom and pan, never touched by SwiftUI. A subview of its own because SwiftUI sets the representable's frame and UIKit answers by shrinking `bounds` until `bounds × transform` equals it, undoing every pinch on the next layout.
    /// A translation is not compensated, so panning looked fine while zoom was broken.
    let contentView = UIView()

    /// The window's rectangle. Not this view's own bounds: the keyboard closing animates this height and the picture swayed re-fitting into each step.
    let clipView: UIView = {
        let view = UIView()
        view.clipsToBounds = true
        return view
    }()

    let displayView = VideoDisplayView()

    /// The outgoing picture, still, under the live one. A source change cannot be made atomic (the layer swaps contents on the render server's clock, the transform is written by the main thread), so the outgoing picture is held at its own scale and cross-faded, and the mismatched pair is never drawn.
    /// An image, not a second decoder: a decoder needs reference frames, so it showed a run's first frame until it caught up. See ``VideoRenderer/displayedPicture()``.
    let stillContentView = UIView()
    let stillView: UIView = {
        let view = UIView()
        // Same fit as the display layer, so rects computed from a pixel size land on the picture exactly.
        view.layer.contentsGravity = .resizeAspect
        // Clear, not black: black bars would cover neighbouring tiles when shrunk into one.
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
        // The scaled content view paints outside the bounds unless clipped, and sublayers are not clipped by default. The clip is ``clipView``.
        addSubview(clipView)

        // Under the live one and sized the same: it is what stays on screen when the live layer fades out.
        for (container, display) in [(backdropContentView, backdropView), (stillContentView, stillView), (contentView, displayView)] {
            container.frame = bounds
            clipView.addSubview(container)
            display.frame = container.bounds
            display.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(display)
        }
        stillContentView.alpha = 0
        backdropContentView.isHidden = true
    }

    /// Sized through `bounds` and `center`, never `frame`: UIKit answers a frame set on a transformed view by shrinking bounds, which undid every zoom.
    override func layoutSubviews() {
        super.layoutSubviews()
        clipView.frame = window.map { convert($0.bounds, from: $0) } ?? bounds
        let size = clipView.bounds.size
        for container in [backdropContentView, stillContentView, contentView] {
            container.bounds = CGRect(origin: .zero, size: size)
            container.center = CGPoint(x: size.width / 2, y: size.height / 2)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Picture in Picture shares the in-app `AVSampleBufferDisplayLayer`, so there is no second decode. Watch-only: the floating window is iOS's, touches never reach the Mac.
@MainActor
@Observable
final class SessionPiP: NSObject {
    static let shared = SessionPiP()

    /// Our own switch because the system's is buried in Settings. Both must allow auto start; this one speaks only for the app. Drawn on every plan, the arming is gated by ``isOnPlan`` in ``applyAutoStart()``.
    var autoStart =
        UserDefaults.standard.object(forKey: PreferenceKeys.pipAutoStart) as? Bool ?? true {
        didSet { applyAutoStart() }
    }

    /// Pushed in from ``SessionModel/applyPictureInPicturePlan()``: this singleton owns no store, to avoid a second copy of the entitlement. False until told, the safe direction, since the automatic start fires without a control being touched so no later gate could ask.
    var isOnPlan = false {
        didSet { applyAutoStart() }
    }

    /// Writes the preference combined with the plan onto the armed controller. Called from both properties and ``attach(_:)`` since the controller is replaced per session.
    private func applyAutoStart() {
        controller?.canStartPictureInPictureAutomaticallyFromInline = autoStart && isOnPlan
    }

    /// Recorded on success too: `enteringBackground` may never reach `start`, and silence looks the same either way.
    private(set) var lastAttempt: String?

    /// PiP refuses without naming the missing prerequisite, so the reason is shown on screen.
    private(set) var lastRefusal: String?

    private var controller: AVPictureInPictureController?

    /// Held weakly: `RemoteScreen` is rebuilt per session and a strong ref would keep a torn-down view and its layer alive.
    private weak var host: VideoDisplayView?

    private override init() { super.init() }

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Where the app was when it asked: separates a broken PiP from one asked at a moment it does not answer. `applicationState` keeps answering as the app leaves.
    private static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: return String(localized: "foreground")
        case .inactive: return String(localized: "on its way out")
        case .background: return String(localized: "background")
        @unknown default: return String(localized: "in an unknown state")
        }
    }

    /// AVKit's own error domain and code for the one failure it explains itself; read in the delegate's `failedToStart` only.
    private static let pictureInPictureErrorDomain = "AVKitErrorDomain"
    private static let sceneNotForegroundCode = -1001

    /// Rebinding on every session: a controller built once on the first session's layer (the `controller == nil` guard) made every later start refuse against a torn-down layer, intermittently.
    func attach(_ view: VideoDisplayView) {
        guard Self.isSupported, host !== view else { return }

        // Stop PiP first: a window left up on a layer nobody owns shows the last session frozen.
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
        // Removes fast-forward, forward-skip and scrubber (a live picture has no ahead). Play/pause and backward-skip have no switch; the delegate's `IsPlaybackPaused` reports false and backward-skip completes immediately.
        controller.requiresLinearPlayback = true
        // Set for the failure callback: without a delegate, a refusal to start is silent.
        controller.delegate = self
        self.controller = controller
        // Last because it writes the switch and plan together onto the controller; going to another app then floats the picture instead of ending the session.
        applyAutoStart()
    }

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// The only place the automatic case can be observed; recorded either way, since never tried and refused both look like silence.
    func backgrounding(sessionIsUp: Bool) {
        guard sessionIsUp else {
            lastAttempt = String(localized: "app left screen with no session up")
            return
        }
        start()
    }

    /// Starts now, to try it without leaving and to say why it will not start.
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
        // Answered first: a running PiP lifts the layer out of the view hierarchy, so the window checks below would misread it as absent.
        if controller.isPictureInPictureActive {
            lastRefusal = nil
            lastAttempt = String(localized: "already active")
            return
        }
        // Checked before `isPictureInPicturePossible`, which does not re-evaluate this: it kept reporting possible for a layer torn down with its screen.
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
            // One line with every prerequisite since PiP refuses without saying which: layer in a visible view, audio session active, video actually rendering.
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
        // Where it was asked is part of the record: a refusal names nothing, so app state is the only difference.
        lastAttempt = String(localized: "asked while \(Self.appState)")
        videoLog.notice("Asking for Picture in Picture while \(Self.appState, privacy: .public)")
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    /// Stops the floating window and releases the content source; a later `attach` builds a controller for the next session.
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

    /// The session screen never left the hierarchy, so tell AVKit restoration is ready when the user taps return.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // No route to rebuild and nothing to await, so restoration succeeded.
        completionHandler(true)
    }

    /// The only place any PiP refusal is named.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        let failure = error as NSError

        // `AVKitErrorDomain` -1001 "Failed to start picture in picture." has exactly one cause: the content source's scene is not foreground active.
        // Expected for the call made on the way out, since `enteringBackground` runs after leaving the foreground, so the sentence is replaced with its meaning. A -1001 is a timing fact, never wiring; other failures arrive silently or under a different domain.
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
    /// Live content, infinite duration. Returning `kCMTimeRangeInvalid` for no content was tried and iOS renders it as a loading spinner over a frozen picture. Transport controls stay; `requiresLinearPlayback` removes some, see ``SessionPiP``.
    func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    /// Never paused: holding frames back is a dropped frame, not a pause.
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
