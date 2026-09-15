import AVFoundation
import AVKit
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

    func makeUIView(context: Context) -> VideoDisplayView {
        let view = VideoDisplayView()
        if let layer = view.displayLayer {
            renderer.attach(layer)
            // The same layer, so the floating window is the picture rather than a copy of it.
            SessionPiP.shared.attach(layer)
        }
        return view
    }

    func updateUIView(_ view: VideoDisplayView, context: Context) {}
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
final class SessionPiP: NSObject {
    static let shared = SessionPiP()

    private var controller: AVPictureInPictureController?

    private override init() { super.init() }

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Binds the layer PiP should mirror. Called once, from `makeUIView`.
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        guard Self.isSupported, controller == nil else { return }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        // The whole point of it: going to another app floats the picture rather than ending
        // the session. Starting it by hand would mean the gesture that matters — leaving the
        // app — is the one that does not trigger it.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
    }

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }
}

extension SessionPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
    /// A live stream has no timeline: it began before the window opened and ends when it ends.
    /// Reporting a finite range instead would give the system's scrubber something to seek in.
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
