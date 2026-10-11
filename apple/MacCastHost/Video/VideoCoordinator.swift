import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import RemoteCore
import os

let coordinatorLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// Owns the capture → encode → send chain, start to finish.
final class VideoCoordinator: @unchecked Sendable {
    let pipeline: CapturePipeline
    let streamer: VideoStreamer
    let adapter = CaptureFrameAdapter()
    let lock = NSLock()

/// Which client is being sent the picture, and which ones have asked for no frames.
    var audience = VideoAudience<PeerConnection>()

    var currentSource: CaptureSource?
    var currentAudioConfig: AudioStreamConfig?

/// Capture start/stop calls are asynchronous, but their ordering is user-visible. The task chain makes
/// them land in the same order as the connection changes recorded under `lock`: in particular, an idle
/// stop always finishes before a replacement peer's start.
    var lifecycleTail: Task<Void, Never>?

/// The source a client chose, as opposed to the default the host fell back to.
    var chosenSource: CaptureSource?

/// What each connected client said it decodes, by key. Absent means it did not say.
    var declaredVideoCodecs: [Data: [String]] = [:]

/// How the next stream is built: the size of its surface, and the rate it is asked for.
    var captureResolution: CaptureResolution = .full
    var captureFrameRate: CaptureFrameRate = .sixty

/// Called when the user changes either one in the host window.
    func setCaptureFormat(resolution: CaptureResolution, frameRate: CaptureFrameRate) {
        lock.withLock {
            captureResolution = resolution
            captureFrameRate = frameRate
        }
    }

/// Fires if capture starts and then produces nothing at all.
    var watchdog: DispatchWorkItem?

    var pendingCatalogPush: Task<Void, Never>?

    /// When the last one went out, so a burst cannot become a storm. See ``refreshCatalog()``.
    var lastCatalogPushAt: Date?

    var pendingCatalogPushID = 0
    var pendingCatalogPushIsWaiting = false

    static let firstFrameGrace: TimeInterval = 5

    /// Called for anything the user should see in the host window. `@Sendable` because this
    /// fires from the capture queue, not the main actor.
    var onStatus: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (CaptureError) -> Void)?

/// The mapping from client coordinates to screen points for the active source, sent whenever it can
/// change.
    var onInputTransform: (@Sendable (InputTransform?) -> Void)?

    var onCatalog: (@Sendable (CaptureCatalog) -> Void)?

    init(pipeline: CapturePipeline) {
        self.pipeline = pipeline

// The streamer asks for a keyframe when a client attaches and whenever the description changes,
// because both invalidate every frame the client's decoder is holding. Routing that through the
// pipeline is what turns it into a real keyframe; without it the client waits out the encoder's
// two-second interval.
        let streamer = VideoStreamer { [weak pipeline] in
            pipeline?.requestKeyframe()
        }
        self.streamer = streamer

        pipeline.onFrame = { [weak self] encoded, source in
            self?.deliver(encoded, source: source)
        }
        pipeline.onFailure = { [weak self] error in
            self?.onFailure?(error)
        }

// Audio is normalized to one wire format here: ScreenCaptureKit may supply either interleaved or
// planar PCM, and the protocol always carries interleaved Float32.
        pipeline.onAudio = { [weak self] sampleBuffer in
            guard let self else { return }
            guard let prepared = Self.prepareAudio(sampleBuffer) else { return }
            let configChanged = self.lock.withLock { () -> Bool in
                guard self.currentAudioConfig != prepared.config else { return false }
                self.currentAudioConfig = prepared.config
                return true
            }
            if configChanged {
                self.streamer.sendAudioConfig(prepared.config)
            }
            self.streamer.sendAudioFrame(prepared.frame)
        }
    }

    static func prepareAudio(
        _ sampleBuffer: CMSampleBuffer
    ) -> (config: AudioStreamConfig, frame: EncodedAudioFrame)? {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0,
              sampleCount <= Int(Int32.max),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }

        let asbd = asbdPointer.pointee
        let channelCount = Int(asbd.mChannelsPerFrame)
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              asbd.mSampleRate.isFinite,
              (8_000...384_000).contains(asbd.mSampleRate),
              (1...32).contains(channelCount),
              let format = AVAudioFormat(streamDescription: asbdPointer),
              let pcm = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(sampleCount)
              )
        else { return nil }

        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: pcm.mutableAudioBufferList
        ) == noErr else { return nil }
        pcm.frameLength = AVAudioFrameCount(sampleCount)

        guard let channels = pcm.floatChannelData else { return nil }
        let stride = pcm.stride
        var samples = Data(capacity: sampleCount * channelCount * MemoryLayout<Float>.size)
        for frameIndex in 0..<sampleCount {
            for channelIndex in 0..<channelCount {
                let sample = channels[channelIndex][frameIndex * stride]
                var littleEndian = sample.bitPattern.littleEndian
                withUnsafeBytes(of: &littleEndian) { samples.append(contentsOf: $0) }
            }
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid, timestamp.timescale > 0 else { return nil }
        let config = AudioStreamConfig(
            codec: .pcmFloat32,
            sampleRate: asbd.mSampleRate,
            channelCount: channelCount
        )
        let frame = EncodedAudioFrame(
            sampleCount: sampleCount,
            channelCount: channelCount,
            presentationTime: VideoTimestamp(value: timestamp.value, timescale: timestamp.timescale),
            samples: samples
        )
        return (config, frame)
    }

    var onGeometry: (@Sendable (FrameGeometry) -> Void)?

/// What is being streamed now, or `nil` when nothing is.
    var onSourceChanged: (@Sendable (CaptureSource?) -> Void)?

    var source: CaptureSource? { lock.withLock { currentSource } }

/// Whether what is being captured is a canvas rather than one of the Mac's sources.
    var isShowingMosaic: Bool { lock.withLock { currentSource?.isMosaic ?? false } }




    // MARK: - Watchdog

    /// The bitrate the client asked for, and the lane in force. Two values rather than one,
    /// because the control channel has a ceiling of its own and the client's figure is what to
    /// go back to when the picture leaves it.
    var requestedBitrateKbps = 0
    var videoTransport: VideoTransport = .primary

    var statistics: CapturePipeline.Statistics { pipeline.statistics }
    var streamStatistics: VideoStreamer.Stats { streamer.stats }
    var isDirectPathOpen: Bool { streamer.isDirectOpen }

    // MARK: - Frame flow

    /// An encoded frame, on VideoToolbox's thread.
    func deliver(_ encoded: EncodedFrame, source: CaptureSource) {
        cancelWatchdog()

        let prepared = adapter.adopt(encoded, sourceID: source.stableID)

        if let config = prepared.config {
            let pending = lock.withLock { audience.described() }
            if let pending {
                streamer.attach(pending, config: config)
            } else if streamer.isAttached {
                streamer.updateConfig(config)
            }
        }

// Submitted unconditionally, including while nothing is attached: the streamer owns the decision to
// buffer or drop, and a frame the host chose not to send is not a frame this layer should be
// second-guessing.
        streamer.submit(prepared.frame)

        if let transform = encoded.geometry.inputTransform ?? pipeline.inputTransform() {
            onInputTransform?(transform)
        }
        if source.contentMovesOnItsOwn {
            onGeometry?(encoded.geometry)
        }
    }
}
