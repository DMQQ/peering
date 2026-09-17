import AVFoundation
import AVKit
import Observation
import CoreMedia
import Foundation
import RemoteCore
import SwiftUI
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
        var framesDropped = 0
        var awaitingKeyframe = true
        var lastError: String?
    }

    private let queue = DispatchQueue(label: "pl.dmq.peering.video", qos: .userInteractive)
    private let lock = NSLock()

    private var renderer: AVSampleBufferVideoRenderer?
    private var formatDescription: CMVideoFormatDescription?
    private var snapshot = Snapshot()
    private var debugTimingOrigin: (arrival: TimeInterval, pts: Double)?
    private var debugTimingFrameCount = 0

    // MARK: - Attachment

    /// Binds the layer this renderer draws into. Called once, from `makeUIView`.
    ///
    /// `AVSampleBufferDisplayLayer` is a `CALayer` and is not `Sendable`, so handing it to
    /// another queue is a transfer the compiler cannot check. It is marked as one deliberately
    /// rather than laundered through a box: this is the only place the layer crosses a thread
    /// boundary, nothing here touches the layer afterwards, and `sampleBufferRenderer` — the
    /// object that is actually used — is documented as safe to enqueue into from a background
    /// thread, which is what makes running the decode path off the main actor possible at all.
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        nonisolated(unsafe) let layer = layer
        queue.async { [weak self] in
            guard let self else { return }
            // The renderer, not the layer. The layer's own `enqueue`/`flush` come from
            // `AVQueuedSampleBufferRendering`, which is deprecated on this class; the modern
            // surface is the `sampleBufferRenderer` it vends.
            self.renderer = layer.sampleBufferRenderer
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
            self.debugTimingOrigin = nil
            self.debugTimingFrameCount = 0
            // The old pictures are in the old format. Flushing before the new frames arrive
            // is what stops the layer rendering a frame whose SPS it has already replaced.
            self.renderer?.flush()

            self.lock.withLock {
                self.snapshot.hasConfig = true
                self.snapshot.pixelWidth = config.pixelWidth
                self.snapshot.pixelHeight = config.pixelHeight
                self.snapshot.codec = config.codec
                self.snapshot.awaitingKeyframe = true
                self.snapshot.lastError = nil
            }
            videoLog.notice("stream configured: \(config.codec.rawValue, privacy: .public) \(config.pixelWidth)x\(config.pixelHeight) with \(config.parameterSets.count) parameter set(s)")
        }
    }

    /// Submits one compressed picture.
    func enqueue(_ frame: EncodedVideoFrame) {
        queue.async { [weak self] in
            guard let self, let renderer = self.renderer, let format = self.formatDescription else {
                return
            }

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

            renderer.enqueue(sample)
            self.lock.withLock {
                self.snapshot.framesEnqueued += 1
                self.snapshot.awaitingKeyframe = false
            }
        }
    }

    /// Drops the stream: the display goes black and the next frame must be a keyframe.
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.renderer?.flush()
            self.formatDescription = nil
            self.debugTimingOrigin = nil
            self.debugTimingFrameCount = 0
            self.lock.withLock {
                self.snapshot = Snapshot()
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
    /// `decodeTimeStamp = .invalid` is correct here and is not a shortcut: the host encodes
    /// with `AllowFrameReordering = false`, so presentation order *is* decode order and there
    /// is no second timestamp to supply. Declaring one would make the layer wait for a
    /// reorder that never comes.
    static func makeSampleBuffer(
        _ frame: EncodedVideoFrame,
        format: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        let length = frame.data.count
        guard length > 0 else { return nil }

        // A block buffer owning its own memory, then a copy in. The alternative — pointing at
        // the frame's bytes — would need the `Data` to outlive the sample buffer, which it
        // does not: the caller drops it the moment this returns.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let copied = frame.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: Self.time(from: frame.presentationTime),
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?

        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        // All three keys are sample-level attachments. AVSampleBufferVideoRenderer reads them
        // from the sample attachment dict (CMSampleBufferGetSampleAttachmentsArray), not from
        // the buffer-level bearer (CMSetAttachment/CMGetAttachment). Setting them at the wrong
        // level is silently ignored.
        //
        // DisplayImmediately: bypasses the timebase scheduler so frames render as they arrive
        // rather than being held until their PTS. Without it the renderer buffers frames until
        // its queue is full, isReadyForMoreMediaData stays false, and P-frames are all dropped.
        //
        // NotSync / DependsOnOthers: tell the renderer which frames are independently
        // decodable. Without them every P-frame looks like a sync sample; the renderer tries
        // to present each one independently, which fails, and only actual keyframes display —
        // one every ~2 seconds.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0,
           let rawDict = CFArrayGetValueAtIndex(attachments, 0) {
            let dict = Unmanaged<CFMutableDictionary>.fromOpaque(rawDict).takeUnretainedValue()
            let isKeyframe = frame.isKeyframe
            func set(_ key: CFString, _ value: CFBoolean) {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(key).toOpaque(),
                    Unmanaged.passUnretained(value).toOpaque()
                )
            }
            set(kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue)
            set(kCMSampleAttachmentKey_NotSync,            isKeyframe ? kCFBooleanFalse : kCFBooleanTrue)
            set(kCMSampleAttachmentKey_DependsOnOthers,    isKeyframe ? kCFBooleanFalse : kCFBooleanTrue)
        }

        return sampleBuffer
    }

    private static func time(from timestamp: VideoTimestamp) -> CMTime {
        // A zero timescale is invalid to CoreMedia and arrives off the network, so it is
        // replaced rather than trusted. 600 is the conventional H.264 timescale.
        let timescale = timestamp.timescale > 0 ? timestamp.timescale : 600
        return CMTime(value: timestamp.value, timescale: CMTimeScale(timescale))
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
    /// The scale the picture is drawn at, applied about its centre.
    var zoom: CGFloat = 1
    /// How far the picture is moved from the centre of its frame, in points.
    var pan: CGSize = .zero

    func makeUIView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        if let layer = view.displayView.displayLayer {
            renderer.attach(layer)
            // The display view rather than the container, so PiP mirrors the layer that is
            // actually holding the picture — the container only ever carries a transform.
            SessionPiP.shared.attach(view.displayView)
        }
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.contentView.transform = target
        CATransaction.commit()
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        contentView.frame = bounds
        addSubview(contentView)

        displayView.frame = contentView.bounds
        // The picture fills whatever this is given, whatever shape that turns out to be.
        displayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(displayView)
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
        contentView.bounds = CGRect(origin: .zero, size: bounds.size)
        contentView.center = CGPoint(x: bounds.midX, y: bounds.midY)
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

    /// Whether iOS should float the picture on its own when the app goes away.
    ///
    /// Our own switch, because the system's is buried. Settings → General → Picture in
    /// Picture → "Start PiP Automatically" is two levels into Settings and reads as a setting
    /// for watching video rather than for driving a Mac — which is why it went unfound for most
    /// of a day's debugging.
    ///
    /// It is a preference *and* a hint. Turning it off does not stop the button, and turning it
    /// on cannot make iOS start something the system-wide setting forbids: both have to allow
    /// it, and this one only speaks for the app.
    var autoStart =
        UserDefaults.standard.object(forKey: PreferenceKey.pipAutoStart) as? Bool ?? true {
        didSet { controller?.canStartPictureInPictureAutomaticallyFromInline = autoStart }
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
        case .inactive: return "on its way out"
        case .background: return "background"
        @unknown default: return "in an unknown state"
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
        // The whole point of it: going to another app floats the picture rather than ending
        // the session. Starting it by hand would mean the gesture that matters — leaving the
        // app — is the one that does not trigger it.
        controller.canStartPictureInPictureAutomaticallyFromInline = autoStart
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
    }

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// Called as the app leaves the screen.
    ///
    /// The one place the automatic case can be observed at all: whether it asked, and what
    /// came back. Recorded either way, because "it never tried" and "it tried and was refused"
    /// are the two halves this has to be told apart from, and both are silence on screen.
    func backgrounding(sessionIsUp: Bool) {
        guard sessionIsUp else {
            lastAttempt = "app left screen with no session up"
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
        guard let controller else {
            lastRefusal = "No picture yet. PiP mirrors the video layer, so a session has to be running."
            lastAttempt = "no layer"
            videoLog.error("Picture in Picture has no layer to mirror yet")
            return
        }
        // Answered before anything is asked about the layer, because a *running* PiP is the one
        // state in which leaving the screen is the whole point: iOS lifts the layer out of the
        // view hierarchy to draw it in its own window, so the window checks below would read a
        // window that is up and working as one that is not there.
        if controller.isPictureInPictureActive {
            lastRefusal = nil
            lastAttempt = "already active"
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
            lastAttempt = "no screen to lift the layer out of"
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
            lastAttempt = "not possible"
            videoLog.error("Picture in Picture is not possible: \(self.lastRefusal ?? "", privacy: .public)")
            return
        }
        lastRefusal = nil
        // Where it was asked is part of the record, not decoration. A start that comes back
        // refused names nothing, and the only difference between a start that should have
        // worked and one that never could is where the app was when it was made.
        lastAttempt = "asked while \(Self.appState)"
        videoLog.notice("Asking for Picture in Picture while \(Self.appState, privacy: .public)")
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }
}

extension SessionPiP: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        videoLog.notice("Picture in Picture started")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        videoLog.notice("Picture in Picture stopped")
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
