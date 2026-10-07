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
nonisolated let videoLog = Logger(subsystem: "pl.dmq.peering", category: "video")

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
