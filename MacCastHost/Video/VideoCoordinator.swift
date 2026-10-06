import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import RemoteCore
import os

private let coordinatorLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// Owns the capture → encode → send chain, start to finish.
final class VideoCoordinator: @unchecked Sendable {
    private let pipeline: CapturePipeline
    private let streamer: VideoStreamer
    private let adapter = CaptureFrameAdapter()
    private let lock = NSLock()

/// Which client is being sent the picture, and which ones have asked for no frames.
    private var audience = VideoAudience<PeerConnection>()

    private var currentSource: CaptureSource?
    private var currentAudioConfig: AudioStreamConfig?

/// Capture start/stop calls are asynchronous, but their ordering is user-visible. The task chain makes
/// them land in the same order as the connection changes recorded under `lock`: in particular, an idle
/// stop always finishes before a replacement peer's start.
    private var lifecycleTail: Task<Void, Never>?

/// The source a client chose, as opposed to the default the host fell back to.
    private var chosenSource: CaptureSource?

/// How the next stream is built: the size of its surface, and the rate it is asked for.
    private var captureResolution: CaptureResolution = .full
    private var captureFrameRate: CaptureFrameRate = .sixty

/// Called when the user changes either one in the host window.
    func setCaptureFormat(resolution: CaptureResolution, frameRate: CaptureFrameRate) {
        lock.withLock {
            captureResolution = resolution
            captureFrameRate = frameRate
        }
    }

/// Fires if capture starts and then produces nothing at all.
    private var watchdog: DispatchWorkItem?

    private var pendingCatalogPush: Task<Void, Never>?

    /// When the last one went out, so a burst cannot become a storm. See ``refreshCatalog()``.
    private var lastCatalogPushAt: Date?

    private var pendingCatalogPushID = 0
    private var pendingCatalogPushIsWaiting = false

    private static let firstFrameGrace: TimeInterval = 5

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

    private static func prepareAudio(
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

    // MARK: - Video clients

    func handleVideoConnection(_ peer: PeerConnection) {
// Weak, because the connection owns this closure. A strong capture would keep the connection alive
// for as long as the streamer holds the peer, which is exactly the leak that makes a disconnected
// client keep receiving frames.
        let announced = peer.onClose
        peer.onClose = { [weak self, weak peer] error in
            announced?(error)
            guard let peer else { return }
            self?.videoPeerClosed(peer)
        }
        serve(peer)
    }

/// Attaches a client's video connection, or holds it until the stream has a description.
    private func serve(_ peer: PeerConnection) {
        let config = adapter.config
        lock.withLock {
            audience.connected(peer, described: config != nil)
            scheduleEnsureCapturingLocked(generation: audience.generation)
        }

        if let config {
            streamer.attach(peer, config: config)
        }
    }

/// Turns the picture on or off for one client, and touches nothing else.
    func setVideoEnabled(_ enabled: Bool, clientKey: Data?) {
        if enabled {
            resumeVideo(clientKey: clientKey)
        } else {
            pauseVideo(clientKey: clientKey)
        }
    }

/// Stops sending frames to a client, keeping its connection.
    private func pauseVideo(clientKey: Data?) {
        let attached = lock.withLock { () -> PeerConnection? in
            guard let served = audience.served, served.peerPublicKey == clientKey else {
// Not a client this Mac is sending frames to. The picture is one stream and one client is
// served at a time, so a second phone that never had it has nothing to stop.
                return nil
            }

            let seat = audience.pause(served)
// The bitrate and the lane were chosen for a link that is about to carry nothing. Left standing, the
// picture that comes back would come back capped to the control channel because of a measurement taken
// before the pause.
            forgetTransportChoiceLocked()
            scheduleStopIfIdleLocked(generation: audience.generation)
            return seat == .attached ? served : nil
        }

        guard let attached else { return }
        // Only if this connection is the one being served. See `detach(ifAttachedTo:)`.
        _ = streamer.detach(ifAttachedTo: attached)
        coordinatorLog.notice("video paused by the client · its session stays up")
    }

/// Starts sending frames to a client that has asked for them again.
    private func resumeVideo(clientKey: Data?) {
        let resumed = lock.withLock {
            audience.pausedConnections.first { $0.peerPublicKey == clientKey }
        }
        guard let resumed else { return }
        serve(resumed)
    }

/// A client's video connection went away.
    private func videoPeerClosed(_ peer: PeerConnection) {
        let seat = lock.withLock { () -> VideoAudience<PeerConnection>.Seat in
            let departure = audience.closed(peer)

// A paused connection was never part of the audience, and an unrelated socket may be one this Mac
// deliberately stopped sending to. Neither changes what the capture is doing, and in particular
// neither advances the generation: a queued start belonging to the connection being served now would
// be discarded, and a client asking for a picture would be left with a capture that never starts.
            guard departure == .waiting || departure == .attached else { return departure }

            chosenSource = nil
// And so does a transport choice. Left standing, the next client, which has asked for nothing, would
// be served a capped picture on the control channel because of a decision somebody else made about a
// link that no longer exists.
            forgetTransportChoiceLocked()
            scheduleStopIfIdleLocked(generation: audience.generation, after: Self.keepCapturingAfterDrop)
            return departure
        }

        switch seat {
        case .attached:
            // Only if this connection is the one being served. See `detach(ifAttachedTo:)`.
            _ = streamer.detach(ifAttachedTo: peer)
            coordinatorLog.notice("video client disconnected")
        case .waiting:
            coordinatorLog.notice("waiting video client disconnected")
        case .unrelated, .paused:
            break
        }
    }

    /// Appends work while `lock` is held. The operation itself never runs under the lock.
    private func scheduleLifecycleLocked(_ operation: @escaping @Sendable () async -> Void) {
        let previous = lifecycleTail
        lifecycleTail = Task {
            if let previous { await previous.value }
            await operation()
        }
    }

    /// How long a freshly attached client is given to say what it wants before this Mac picks
    /// for it.
    private static let firstAskGrace = Duration.seconds(1)

    private func scheduleEnsureCapturingLocked(generation: UInt64) {
        scheduleLifecycleLocked { [weak self] in
            guard let self, self.hasAudience(generation: generation) else { return }

// A client that has just attached has usually already said what it wants. The catalogue goes out the
// moment it connects, and what comes back is the source it was last on, usually a mosaic. Starting the
// default display in the meantime builds a stream that is thrown away a round trip later, and the phone
// watches it happen: a desktop appears, and then the arrangement it was waiting for.
            if self.lock.withLock({ self.chosenSource }) == nil {
                try? await Task.sleep(for: Self.firstAskGrace)
                guard self.hasAudience(generation: generation) else { return }
            }

            do {
                try await self.ensureCapturing()
                guard self.hasAudience(generation: generation) else { return }
                self.pipeline.requestKeyframe()
            } catch {
                self.onFailure?(error as? CaptureError ?? .encodingFailed("\(error)"))
            }
        }
    }

    /// How long capture outlives a viewer that dropped, so one that reconnects gets a keyframe at
    /// once instead of waiting for a new stream. Only for a connection that closed: a pause stops
    /// at once, because saving the battery is what it was asked for.
    private static let keepCapturingAfterDrop = Duration.seconds(15)

    /// Not a sleep on the lifecycle queue, which would hold up the next viewer's start: the stop is
    /// queued when the time is up, and only if nobody has attached since.
    private func scheduleStopIfIdleLocked(generation: UInt64, after delay: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.lock.withLock {
                guard self.audience.generation == generation else { return }
                self.scheduleStopIfIdleLocked(generation: generation)
            }
        }
    }

    private func scheduleStopIfIdleLocked(generation: UInt64) {
        scheduleLifecycleLocked { [weak self] in
            guard let self, self.isIdle(generation: generation) else { return }
            self.cancelWatchdog()
            await self.pipeline.stop()
            self.adapter.forget()
            let remainsIdle = self.lock.withLock { () -> Bool in
                self.currentSource = nil
                return self.audience.generation == generation && self.audience.isIdle
            }
            self.onInputTransform?(nil)
            if remainsIdle {
// A client that asked for no frames is still here, and the status line has to be able to tell that
// from a client that left: "no video clients" over a session that is still up reads as a bug.
                let paused = self.lock.withLock { !self.audience.pausedConnections.isEmpty }
                let reason = paused
                    ? "Capture stopped · paused by the client"
                    : "Capture stopped · no video clients"
                self.onStatus?(reason)
                coordinatorLog.notice("\(reason, privacy: .public)")
            }
        }
    }

    private func hasAudience(generation: UInt64) -> Bool {
        lock.withLock {
            audience.generation == generation && !audience.isIdle
        }
    }

    private func isIdle(generation: UInt64) -> Bool {
        lock.withLock {
            audience.generation == generation && audience.isIdle
        }
    }

    // MARK: - Catalogue

/// Re-reads the source list and offers it to ``onCatalog``.
    func forgetWindowListIfStale() {
        pipeline.forgetWindowListIfStale()
    }

    /// Drops the cached window list and sends the phone a fresh one, for a change this host made.
    func refreshWindowList() {
        pipeline.forgetWindowList()
        refreshCatalog(immediate: true)
    }

    func refreshCatalog(immediate: Bool = false) {
        lock.withLock {
            if let pending = pendingCatalogPush {
                guard immediate, pendingCatalogPushIsWaiting else { return }
                pending.cancel()
            }
            let since = lastCatalogPushAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let wait = immediate ? 0 : max(0, Self.catalogPushInterval - since)
            pendingCatalogPushID &+= 1
            let id = pendingCatalogPushID
            pendingCatalogPushIsWaiting = wait > 0
            pendingCatalogPush = Task { [weak self] in
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let self else { return }
                let current = self.lock.withLock { () -> Bool in
                    guard self.pendingCatalogPushID == id else { return false }
                    self.lastCatalogPushAt = Date()
                    self.pendingCatalogPush = nil
                    self.pendingCatalogPushIsWaiting = false
                    return true
                }
                guard current else { return }
                await self.pushCatalog()
            }
        }
    }

    private static let catalogPushInterval: TimeInterval = 3

    private func pushCatalog() async {
        do {
            let catalog = try await pipeline.catalog()

// Offered every time, with no "unchanged, skip it" check here. A host-wide "last catalogue" cannot
// tell which client already has it, so it answers "nobody needs this" for every client that has not
// connected yet: the first client suppressed the push for all the others, and every later client got
// an empty source picker. The suppression belongs where the knowledge is: each ``HostSession``
            onCatalog?(catalog)
// The Space count and preview count are the only way to tell a host that has never seen a desktop
// from one that has: both send the same picker, and the difference is a screenshot that either
// happened or was refused.
            coordinatorLog.notice("""
                capture catalogue · \(catalog.displays.count, privacy: .public) display(s), \
                \(catalog.applications.count, privacy: .public) application(s), \
                \(catalog.windows.count, privacy: .public) window(s), \
                \(catalog.installedApplications.count, privacy: .public) installed application(s), \
                \(catalog.spaceInfo?.displays.count ?? 0, privacy: .public) display(s) with \
                \(catalog.spaceInfo?.totalCount ?? 0, privacy: .public) space(s) \
                and \(catalog.spaceInfo?.previews.count ?? 0, privacy: .public) preview(s)
                """)
        } catch {
            coordinatorLog.notice("""
                could not read the capture catalogue: \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    // MARK: - Capture

    static var defaultSource: CaptureSource {
        .display(UInt32(CGMainDisplayID()))
    }

    private func ensureCapturing() async throws {
        let target = lock.withLock { chosenSource ?? Self.defaultSource }
        guard lock.withLock({ currentSource }) != target else { return }
        try await startCapture(target)
    }

/// Switches what is being captured.
    func switchSource(_ source: CaptureSource) async throws {
        let operation = lock.withLock { () -> Task<Void, Error> in
// Recorded before the switch, not after, so the intent is the client's even if the capture fails.
// Scheduling under the same lock also orders a disconnect after this switch, rather than letting its
// stop race the pipeline start.
            chosenSource = source
            let previous = lifecycleTail
            let operation = Task { [weak self] in
                if let previous { await previous.value }
                guard let self else { return }
                guard self.lock.withLock({ !self.audience.isIdle }) else { return }
                if self.lock.withLock({ self.currentSource }) == source {
                    self.pipeline.requestKeyframe()
                    self.onSourceChanged?(source)
                    return
                }
                try await self.startCapture(source)
            }
            lifecycleTail = Task { _ = await operation.result }
            return operation
        }

        do {
            try await operation.value
        } catch {
// The choice did not take, so it is not the client's any more: whatever is running stands, or nothing
// does, and the next client is not walked into retrying a source that has already failed once.
            lock.withLock { if chosenSource == source { chosenSource = currentSource } }
            throw error
        }
    }

    private func startCapture(_ source: CaptureSource) async throws {
// Read here rather than when they were set: this is the one moment either of them can take effect.
// Read under one lock, so a pair the user changed while this was queued cannot be split across two
// streams.
        let (resolution, frameRate) = lock.withLock { (captureResolution, captureFrameRate) }
        // Before the start, because the description it holds belongs to the source being replaced:
        adapter.forget()
        try await pipeline.start(
            source: source,
            frameRate: frameRate.rawValue,
            resolution: resolution
        )
        lock.withLock { currentSource = source }
        onSourceChanged?(source)
        armWatchdog(source: source)
        onStatus?("Capturing \(source.description)")
        coordinatorLog.notice("""
            capture started · \(source.description, privacy: .public) at \
            \(resolution.rawValue, privacy: .public) size \
            @ \(frameRate.rawValue, privacy: .public) fps
            """)
    }

    // MARK: - Watchdog

    private func armWatchdog(source: CaptureSource) {
        let item = DispatchWorkItem { [weak self] in
            self?.reportNoFrames(source: source)
        }
        let previous = lock.withLock { () -> DispatchWorkItem? in
            let old = watchdog
            watchdog = item
            return old
        }
        previous?.cancel()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.firstFrameGrace,
            execute: item
        )
    }

    private func cancelWatchdog() {
        let item = lock.withLock { () -> DispatchWorkItem? in
            let current = watchdog
            watchdog = nil
            return current
        }
        item?.cancel()
    }

    private func reportNoFrames(source: CaptureSource) {
        let stats = statistics
        let permission = CGPreflightScreenCaptureAccess()
        coordinatorLog.error("""
            capture produced no frames in \(Int(Self.firstFrameGrace), privacy: .public)s · \
            source \(source.description, privacy: .public) · \
            screen recording \(permission ? "granted" : "NOT granted", privacy: .public) · \
            stream delivered \(stats.framesDelivered, privacy: .public), \
            idle \(stats.idleSamples, privacy: .public)
            """)

// Frames that carry no picture are still frames, and a stream reporting them is working: it is
// delivering on schedule and the screen is not changing. The two counters together are what tell the
// difference, which is why ``CaptureEngine`` counts both.
        if stats.idleSamples > 0 && stats.framesDelivered == 0 {
            onStatus?("Capturing \(source.description) · nothing new to send yet")
            return
        }

        guard permission else {
            onFailure?(.screenRecordingDenied)
            return
        }

// Do not drop the window from the list: a stream that produces nothing is also what a minimised,
// hidden or off-Space window does, and those are ordinary states.

        onFailure?(.streamFailed(
            "Capture started but produced no frames from \(source.description), and Screen "
                + "Recording permission is granted. The source may have gone away."
        ))
    }

    func refreshSpacePreviews() {
        pipeline.refreshSpacePreviews()
    }

/// A source this Mac has been asked for and cannot capture, so the catalogue stops offering it.
    func markUncapturable(_ source: CaptureSource) {
        pipeline.markUncapturable(source)
    }

    func refreshSourceThumbnails() {
        pipeline.refreshSourceThumbnails()
    }

    func watchSourceThumbnails(_ watching: Bool) {
        pipeline.watchSourceThumbnails(watching)
    }

    func snapshot(maxWidth: Int) async -> CGImage? {
        await pipeline.snapshot(maxWidth: maxWidth)
    }

/// Applies a stream-quality change requested by the client.
    func setStreamQuality(fps: Int, bitrateKbps: Int) {
        guard bitrateKbps > 0 else { return }
        lock.withLock { requestedBitrateKbps = bitrateKbps }
        pipeline.setBitrate(effectiveBitrateKbps * 1000)
    }

/// Moves video between the transport the client prefers and the control channel.
    func setVideoTransport(_ request: VideoTransportRequest, clientKey: Data?, controlPeer: PeerConnection) {
        let served = lock.withLock { audience.served }
        if let served, let clientKey, served.peerPublicKey != clientKey {
// Somebody else's picture. A session is served by one client at a time, and redirecting the stream to
// a second one on that client's say-so is the one thing the authorization check on a video connection
// exists to prevent.
            coordinatorLog.notice("refused a video transport request from a client that is not being served")
            return
        }
        guard served != nil else {
// Nothing to move. A client with no video peer at all is one whose video connection never arrived,
// which is a different failure with a different message already on its screen.
            coordinatorLog.notice("refused a video transport request: no video client is attached")
            return
        }

        switch request.transport {
        case .control:
            guard streamer.isProducing(within: Self.producingWindow) else {
// A still screen produces no frames at all, and neither does a capture that never started. Moving the
// stream in either case would cap the rate and change nothing else, so the request is declined and the
// client asks again shortly, by which time there is either a picture to move or nothing to move it for.
                coordinatorLog.notice("declined the control-channel fallback: nothing has been produced recently")
                return
            }
            guard streamer.use(transport: .control, controlPeer: controlPeer) else { return }
            lock.withLock { videoTransport = .control }
            pipeline.setBitrate(effectiveBitrateKbps * 1000)
            coordinatorLog.notice("video moved to the control channel · \(request.reason, privacy: .public)")

        case .primary:
            streamer.use(transport: .primary, controlPeer: nil)
            lock.withLock { videoTransport = .primary }
            pipeline.setBitrate(effectiveBitrateKbps * 1000)
            coordinatorLog.notice("video moved back to the transport the client prefers · \(request.reason, privacy: .public)")
        }
    }

/// Opens the relay's datagram path for a client that asked for it.
    func enableVideoDatagrams(clientKey: Data?, relay: RelaySession) -> Data? {
        let served = lock.withLock { audience.served }
        if let served, let clientKey, served.peerPublicKey != clientKey {
            coordinatorLog.notice("refused a video datagram request from a client that is not being served")
            return nil
        }
        guard served != nil else {
            coordinatorLog.notice("refused a video datagram request: no video client is attached")
            return nil
        }
        guard let secret = VideoKeySchedule.randomSecret() else {
            coordinatorLog.error("no secure random for a video secret; the picture stays on the control channel")
            return nil
        }

        do {
            let lane = try VideoDatagramLane(relay: relay, secret: secret)
            guard streamer.useDatagrams(lane) else { return nil }
            coordinatorLog.notice("video is going on the relay's datagram path")
            return secret
        } catch {
            coordinatorLog.error("could not open the relay's video datagram path: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The bitrate the client asked for, and the lane in force. Two values rather than one,
    /// because the control channel has a ceiling of its own and the client's figure is what to
    /// go back to when the picture leaves it.
    private var requestedBitrateKbps = 0
    private var videoTransport: VideoTransport = .primary

    /// Drops both halves of the choice above, for an audience that has ended or paused.
    /// Call with `lock` held.
    private func forgetTransportChoiceLocked() {
        videoTransport = .primary
        requestedBitrateKbps = 0
    }

/// What the encoder should be running at: the client's choice, and the control channel's ceiling on top
/// of it.
    private var effectiveBitrateKbps: Int {
        lock.withLock {
            let asked = requestedBitrateKbps > 0
                ? requestedBitrateKbps
                : VideoFallbackPolicy.preferredTransportBitrateKbps
            guard videoTransport == .control else { return asked }
            return min(asked, VideoFallbackPolicy.controlChannelBitrateKbps)
        }
    }

    /// How recently the encoder must have produced something for the host to believe that a
    /// missing picture is the network's doing rather than there being no picture.
    private static let producingWindow: TimeInterval = 5

    func stop() {
// Before anything else: a teardown must not be reported as a failure to capture.
        cancelWatchdog()
        lock.withLock {
            currentSource = nil
            chosenSource = nil
            audience.removeAll()
            forgetTransportChoiceLocked()
            scheduleLifecycleLocked { [weak self, pipeline] in
                await pipeline.stop()
                guard let self else { return }
                self.adapter.forget()
                self.lock.withLock { self.currentSource = nil }
            }
        }
        streamer.detach()
        onSourceChanged?(nil)
        onInputTransform?(nil)
    }

    var statistics: CapturePipeline.Statistics { pipeline.statistics }
    var streamStatistics: VideoStreamer.Stats { streamer.stats }
    var isDirectPathOpen: Bool { streamer.isDirectOpen }

    // MARK: - Frame flow

    /// An encoded frame, on VideoToolbox's thread.
    private func deliver(_ encoded: EncodedFrame, source: CaptureSource) {
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

extension CaptureSource {
    fileprivate var description: String {
        switch self {
        case .display(let id): return "display \(id)"
        case .application(let pid): return "application \(pid)"
        case .window(let id): return "window \(id)"
        case .mosaic(let layout): return "a mosaic of \(layout.tiles.count) sources"
        }
    }
}
