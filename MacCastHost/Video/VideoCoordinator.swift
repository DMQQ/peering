import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import RemoteCore
import os

private let coordinatorLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// Owns the capture → encode → send chain, start to finish.
///
/// Deliberately not `@MainActor`: frames arrive up to sixty times a second from VideoToolbox, and
/// routing each one through the main actor would put the video path behind whatever SwiftUI happens
/// to be doing. `HostModel` keeps the main-actor state the window needs; everything below it lives
/// here, and the only things that cross back are status strings and failures.
///
/// It exists as a type because of one ordering rule that is easy to get wrong and impossible to see
/// when it is: a client cannot be sent a frame before it has been sent the description needed to
/// decode that frame. Parameter sets live in the encoder's format description, which does not exist
/// until the encoder has produced its first frame, so a video connection cannot be served on arrival.
/// It has to wait for a keyframe, and this is where that wait is kept.
final class VideoCoordinator: @unchecked Sendable {
    private let pipeline: CapturePipeline
    private let streamer: VideoStreamer
    private let adapter = CaptureFrameAdapter()
    private let lock = NSLock()

/// Which client is being sent the picture, and which ones have asked for no frames.
///
/// Kept here as well as in `VideoStreamer` so connection lifetime and capture lifetime can be changed
/// under one lock. A paused connection is one of these rather than nothing at all: the client is still
/// connected and still coming back, and the socket it is holding is the expensive thing a resume would
/// otherwise have to rebuild.
    private var audience = VideoAudience<PeerConnection>()

    /// The source the stream is on, or `nil` when nothing is being captured.
    private var currentSource: CaptureSource?
    private var currentAudioConfig: AudioStreamConfig?

/// Capture start/stop calls are asynchronous, but their ordering is user-visible. The task chain makes
/// them land in the same order as the connection changes recorded under `lock`: in particular, an idle
/// stop always finishes before a replacement peer's start.
    private var lifecycleTail: Task<Void, Never>?

/// The source a client chose, as opposed to the default the host fell back to.
///
/// The two are not interchangeable even when they name the same source, because they have different
/// lifetimes: a default belongs to the host and outlives everyone, while a choice belongs to the
/// client that made it. So it outlives a pause and not a disconnect.
///
/// Held as the source itself rather than as a flag beside ``currentSource``, because a paused capture
/// has no running source to remember the choice by: the stop clears ``currentSource``, and a flag
/// alone would leave the next start with nothing to name but the default display.
    private var chosenSource: CaptureSource?

/// How the next stream is built: the size of its surface, and the rate it is asked for.
///
/// Read when a capture starts and not when they are set, because neither can be changed on a stream
/// that is already running: the surface's dimensions and its frame interval are fixed when the
/// `SCStream` is created, and the encoder is built around them. What the window shows for them is a
/// promise about the next capture. Under ``lock`` with the rest of the state, since the window writes
/// them on the main actor while the lifecycle queue reads them.
    private var captureResolution: CaptureResolution = .full
    private var captureFrameRate: CaptureFrameRate = .sixty

/// Called when the user changes either one in the host window.
///
/// Both at once rather than one at a time: the pair is what the next capture is built from, and a
/// setter that wrote only its own half would leave the other one holding whatever it was last given.
    func setCaptureFormat(resolution: CaptureResolution, frameRate: CaptureFrameRate) {
        lock.withLock {
            captureResolution = resolution
            captureFrameRate = frameRate
        }
    }

/// Fires if capture starts and then produces nothing at all.
///
/// This exists because the failure it catches is otherwise invisible. Without Screen Recording
/// permission, `SCShareableContent` still hands back a catalogue, the content filter still builds, and
/// `startCapture` still returns without error, and then no frames ever arrive. Nothing throws, nothing
/// logs, and the host window says "Capturing Built-in Retina Display" while the client shows a black
/// rectangle.
///
/// It covers the start window only, and that restriction is what makes it correct rather than noisy.
/// A static screen also produces no frames, but it still delivers its first one, so "no frame has ever
/// arrived" distinguishes a dead stream from a still one and a later silence is not evidence of
/// anything.
    private var watchdog: DispatchWorkItem?

    /// The catalogue push a burst of invalidations is already owed. See ``refreshCatalog()``.
    private var pendingCatalogPush: Task<Void, Never>?

    /// When the last one went out, so a burst cannot become a storm. See ``refreshCatalog()``.
    private var lastCatalogPushAt: Date?

/// How long capture may go without producing a single frame before it is called dead. Generous: the
/// first frame has to survive encoder creation and a stream start, and a false accusation here sends
/// the user to System Settings for no reason.
    private static let firstFrameGrace: TimeInterval = 5

    /// Called for anything the user should see in the host window. `@Sendable` because this
    /// fires from the capture queue, not the main actor.
    var onStatus: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (CaptureError) -> Void)?

/// The mapping from client coordinates to screen points for the active source, sent whenever it can
/// change.
///
/// Re-published on every source start rather than computed once, because it depends on the source: a
/// display maps through the display's bounds, while a window or an application maps through wherever
/// that content happens to be. Nil means nothing is being captured and the caller should fall back to
/// the display it is looking at.
    var onInputTransform: (@Sendable (InputTransform?) -> Void)?

    /// Called with the source list whenever it changes. The host pushes it to clients so
    /// their picker offers what actually exists right now, rather than what existed when
    /// they connected.
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

        pipeline.onFrame = { [weak self] encoded in
            self?.deliver(encoded)
        }
        pipeline.onGeometry = { [weak self] geometry in
            guard let self else { return }
            guard self.source?.contentMovesOnItsOwn == true else { return }
            self.onGeometry?(geometry)
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

    /// Where the captured content currently sits, for mapping client input. Nil until a
    /// frame has reported it.
    var onGeometry: (@Sendable (FrameGeometry) -> Void)?

/// What is being streamed now, or `nil` when nothing is.
///
/// Reported rather than pulled, because the answer changes for reasons the window never sees, and it
/// is decided on the lifecycle queue while the window is read on the main actor. ``source`` below
/// answers the same question, but only to a caller who already knows when to ask.
    var onSourceChanged: (@Sendable (CaptureSource?) -> Void)?

    /// The capture source being captured, if any.
    var source: CaptureSource? { lock.withLock { currentSource } }

/// Whether what is being captured is a canvas rather than one of the Mac's sources.
///
/// Read by the input path, which refuses user input while one is up: a point on a canvas means
/// nothing on the Mac until a tile has been chosen for it, and the tile is chosen on the phone.
/// See ``CaptureSource/isMosaic``.
    var isShowingMosaic: Bool { lock.withLock { currentSource?.isMosaic ?? false } }

    // MARK: - Video clients

    /// A client has opened a video connection, and the host has already checked that a live
    /// authorized control session belongs to the same key. Called on the server queue.
    func handleVideoConnection(_ peer: PeerConnection) {
// Weak, because the connection owns this closure. A strong capture would keep the connection alive
// for as long as the streamer holds the peer, which is exactly the leak that makes a disconnected
// client keep receiving frames.
//
// Chained, not assigned. A relayed session's video "connection" is the control connection itself,
// which the session has already claimed to know when its peer goes away, and replacing that handler
// would take the teardown with it: the session would never leave the server's list and the datagram
// lane, whose whole lifetime is this one, would go on sending to a client that has gone.
        let announced = peer.onClose
        peer.onClose = { [weak self, weak peer] error in
            announced?(error)
            guard let peer else { return }
            self?.videoPeerClosed(peer)
        }
        serve(peer)
    }

/// Attaches a client's video connection, or holds it until the stream has a description.
///
/// Shared by a connection that has just arrived and by one a client is asking for again after a
/// pause, because the two are the same event. The only difference is where the connection came from,
/// and a second path for it is how the two would come to disagree about the keyframe.
    private func serve(_ peer: PeerConnection) {
        let config = adapter.config
        lock.withLock {
            audience.connected(peer, described: config != nil)
            scheduleEnsureCapturingLocked(generation: audience.generation)
        }

        if let config {
// The description is already known from a previous client or an earlier frame, so there is nothing to
// wait for. The attach itself asks for a keyframe, which gives this client a picture it can decode
// without waiting out the encoder's interval.
            streamer.attach(peer, config: config)
        }
    }

/// Turns the picture on or off for one client, and touches nothing else.
///
/// This is the whole of the host's half of ``RemoteCommand/setVideoEnabled(_:)``, and the property it
/// exists to preserve is that only the frames change. The session, the control channel, the terminals,
/// the clipboard and the assertion that keeps this Mac awake are all somebody else's business.
///
/// The client is identified by the key it presented rather than by the connection the request arrived
/// on: in a direct session the request arrives on the control connection while the frames go out on a
/// socket of their own, so the connection carrying the command is never the connection to act on.
    func setVideoEnabled(_ enabled: Bool, clientKey: Data?) {
        if enabled {
            resumeVideo(clientKey: clientKey)
        } else {
            pauseVideo(clientKey: clientKey)
        }
    }

/// Stops sending frames to a client, keeping its connection.
///
/// What stops is the capture, if this was the last client asking for a picture, and the bytes going to
/// this one. What is deliberately not done is closing anything: on a direct session reopening the video
/// socket costs a fresh TLS handshake, and on a relayed one the control connection is the video
/// connection.
///
/// The source choice survives, unlike on a disconnect, because the client has not gone anywhere and the
/// window it was watching is the one it must come back to.
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
///
/// The connection attached is the one this client paused, because it is still open and because it is
/// the expensive thing to rebuild. When there is none there is nothing to attach, and the connection it
/// opens next is served the way any new one is.
    private func resumeVideo(clientKey: Data?) {
        let resumed = lock.withLock {
            audience.pausedConnections.first { $0.peerPublicKey == clientKey }
        }
        guard let resumed else { return }
        serve(resumed)
    }

/// A client's video connection went away.
///
/// The capture is not stopped by every close, only by one that takes the last of the audience with it,
/// because a client that reconnects has a new connection accepted before the old one is reaped.
    private func videoPeerClosed(_ peer: PeerConnection) {
        let seat = lock.withLock { () -> VideoAudience<PeerConnection>.Seat in
            let departure = audience.closed(peer)

// A paused connection was never part of the audience, and an unrelated socket may be one this Mac
// deliberately stopped sending to. Neither changes what the capture is doing, and in particular
// neither advances the generation: a queued start belonging to the connection being served now would
// be discarded, and a client asking for a picture would be left with a capture that never starts.
            guard departure == .waiting || departure == .attached else { return departure }

// A source choice belongs to the departed audience. Clear it synchronously so a replacement queued
// behind the stop selects the host's default source.
            chosenSource = nil
// And so does a transport choice. Left standing, the next client, which has asked for nothing, would
// be served a capped picture on the control channel because of a decision somebody else made about a
// link that no longer exists.
            forgetTransportChoiceLocked()
            scheduleStopIfIdleLocked(generation: audience.generation)
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
    ///
    /// A round trip was the whole of this number, and a round trip is not the whole of the wait:
    /// the phone asks from what the catalogue names, so its ask goes out a round trip *after* that
    /// list arrives, and the list costs an enumeration and a screen's worth of icons to build. A
    /// quarter of a second therefore lost the race on every connection whose ask has any distance
    /// to travel, which is visible as a desktop appearing first and being replaced.
    ///
    /// Paid by a client that asks for nothing, which is one that has never chosen a source, and
    /// paid once per video connection. See ``ensureCapturing()``.
    private static let firstAskGrace = Duration.seconds(1)

    private func scheduleEnsureCapturingLocked(generation: UInt64) {
        scheduleLifecycleLocked { [weak self] in
            guard let self, self.hasAudience(generation: generation) else { return }

// A client that has just attached has usually already said what it wants. The catalogue goes out the
// moment it connects, and what comes back is the source it was last on, usually a mosaic. Starting the
// default display in the meantime builds a stream that is thrown away a round trip later, and the phone
// watches it happen: a desktop appears, and then the arrangement it was waiting for.
//
// Waiting is free when the client does ask, because ``switchSource(_:)`` records the choice the moment
// the command arrives rather than when its turn comes, so the check below sees it. It is only ever paid
// by a client that wants the default, and then only once.
            if self.lock.withLock({ self.chosenSource }) == nil {
                try? await Task.sleep(for: Self.firstAskGrace)
                guard self.hasAudience(generation: generation) else { return }
            }

            do {
                try await self.ensureCapturing()
                guard self.hasAudience(generation: generation) else { return }
// If capture had to be started for this connection, the attach above asked for a keyframe before
// there was an encoder to hear it.
                self.pipeline.requestKeyframe()
            } catch {
                self.onFailure?(error as? CaptureError ?? .encodingFailed("\(error)"))
            }
        }
    }

    private func scheduleStopIfIdleLocked(generation: UInt64) {
        scheduleLifecycleLocked { [weak self] in
            guard let self, self.isIdle(generation: generation) else { return }
            self.cancelWatchdog()
            await self.pipeline.stop()
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
///
/// Called when a client connects, and again whenever the resolver reports the list may have changed.
/// Reading it needs Screen Recording permission, so this is also the point at which a client can be
/// told the list is unavailable; a failure here is not worth interrupting anyone over, since a client
/// that never receives a catalogue is still served the default display.
///
/// Coalesced, because every caller is a notification and notifications arrive in bursts. Each push is
/// a full enumeration of the Mac's applications, its windows and its desktops, with a screenshot of
/// every Space in it, on the same machine that is compositing the picture. The last request is always
/// honoured, so nothing genuinely asked for is skipped.
///
/// - Parameter immediate: skip the interval, for the one caller that is not a change to the list but
///   a client with none: see ``HostModel``'s `.clientConnected`. A client waits on this list before
///   it can ask for the source it was last on, and the interval was holding that up for up to three
///   seconds, which is how a desktop came to appear before the arrangement the phone had asked for.
    func refreshCatalog(immediate: Bool = false) {
        lock.withLock {
            guard pendingCatalogPush == nil else { return }
            let since = lastCatalogPushAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let wait = immediate ? 0 : max(0, Self.catalogPushInterval - since)
            pendingCatalogPush = Task { [weak self] in
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let self else { return }
                self.lock.withLock {
                    self.lastCatalogPushAt = Date()
                    self.pendingCatalogPush = nil
                }
                await self.pushCatalog()
            }
        }
    }

    /// The shortest gap between two catalogue pushes. See ``refreshCatalog()``.
    private static let catalogPushInterval: TimeInterval = 3

    private func pushCatalog() async {
        do {
            let catalog = try await pipeline.catalog()

// Offered every time, with no "unchanged, skip it" check here. A host-wide "last catalogue" cannot
// tell which client already has it, so it answers "nobody needs this" for every client that has not
// connected yet: the first client suppressed the push for all the others, and every later client got
// an empty source picker. The suppression belongs where the knowledge is: each ``HostSession``
// remembers what it has already sent.
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

/// What to capture when a client connects without having chosen anything.
///
/// `CGMainDisplayID()` is safe to call without Screen Recording permission, since it reports which
/// display the cursor is on and not what is on it, so this can be computed before the permission
/// question is even asked.
    static var defaultSource: CaptureSource {
        .display(UInt32(CGMainDisplayID()))
    }

/// Starts capturing if nothing is, or if what is being captured is a decision nobody is left to have
/// made.
///
/// The question is deliberately not "is anything being captured": a stream left running on a departed
/// client's source is still running, and answering the narrow question is what let it be shown to the
/// next client. See ``videoPeerClosed(_:)``.
///
/// A paused client is the case that makes the choice worth keeping as a source rather than as a flag
/// beside the running one: capture stops while it is paused, and this is what comes back to the window
/// it was watching rather than to the host's default display.
///
/// The default is not restarted when it is already running, which is every client after the first on
/// an untouched host: `startCapture` rebuilds the `SCStream` rather than reusing it, so an unnecessary
/// call is a few hundred milliseconds of black for no change in the picture.
    private func ensureCapturing() async throws {
        let target = lock.withLock { chosenSource ?? Self.defaultSource }
        guard lock.withLock({ currentSource }) != target else { return }
        try await startCapture(target)
    }

/// Switches what is being captured.
///
/// The video connection survives; the capture stream does not. `switchSource` goes through
/// ``startCapture(_:)``, which stops the running `SCStream` and builds a new one for the new source,
/// rather than calling `SCStream.updateContentFilter(_:)`. That is a deliberate trade: an in-place
/// filter swap still owes the client a fresh keyframe and still leaves the encoder holding a surface of
/// the old size, so it would save the stream setup and nothing else while adding a second path whose
/// failure mode is a stream producing frames in the wrong shape.
///
/// The client sees no reconnect either way: the new surface produces new parameter sets, the adapter
/// reports that as a description change, and the streamer re-sends the config and forces a keyframe.
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
// Nothing is captured for an audience of nobody. A client that has paused has asked for no frames and
// the capture has stopped, so its switch is kept and not acted on: starting a stream here would be the
// battery the pause was asked for, spent on a picture nobody is being sent. What starts it is the
// resume, which is a connection arriving like any other: see ``serve(_:)``.
                guard self.lock.withLock({ !self.audience.isIdle }) else { return }
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
        try await pipeline.start(
            source: source,
            frameRate: frameRate.rawValue,
            resolution: resolution
        )
        lock.withLock { currentSource = source }
        onSourceChanged?(source)
        onInputTransform?(pipeline.inputTransform())
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

/// Capture started and then produced nothing. Ask the system which of the two causes it is, rather
/// than guessing: the remedy is completely different, and one of them is a button the user has to press
/// in System Settings.
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
//
// This signature has a second cause worth knowing: a frame-status reader that answers `nil` for every
// frame puts the stream in exactly this state, alive at full rate with nothing ever delivered. If this
// branch ever becomes the normal case rather than a rare one, the status read is the first thing to
// check.
        if stats.idleSamples > 0 && stats.framesDelivered == 0 {
            onStatus?("Capturing \(source.description) · nothing new to send yet")
            return
        }

        guard permission else {
            onFailure?(.screenRecordingDenied)
            return
        }

// **And it stops being offered.** A window ScreenCaptureKit lists and will not render is
// indistinguishable from a capturable one until a stream built for it says nothing at all, and this
// is that moment: without this the window stays in the phone's list for as long as the two ends are
// connected, and every tap on it is a tap that does nothing. A display is the exception, and not
// because a broken one is not broken: it is the thing a phone needs whatever state it is in, and
// taking it out of the list leaves the client with nothing to look at and nothing to ask for.
        switch source {
        case .window, .application:
            pipeline.markUncapturable(source)
        case .display, .mosaic:
            break
        }

// Permission is fine, so the stream itself is the problem. Say what was being captured and that
// permission was not the reason, or the next reader goes looking in System Settings for something
// already correct.
        onFailure?(.streamFailed(
            "Capture started but produced no frames from \(source.description), and Screen "
                + "Recording permission is granted. The source may have gone away."
        ))
    }

/// Re-photographs the desktop showing on each display. See
/// ``RemoteCommand/refreshSpacePreviews``.
    func refreshSpacePreviews() {
        pipeline.refreshSpacePreviews()
    }

/// A source this Mac has been asked for and cannot capture, so the catalogue stops offering it.
///
/// **The other half of the evidence ``markUncapturable(_:)`` is fed by.** A window a stream was
/// built for and got nothing out of is one kind; a window whose filter cannot be built at all is
/// another and arrives here, at the ask, before any stream exists. Both look identical from the
/// phone: a row in the picker that does nothing when it is pressed, for as long as the two ends
/// are connected.
    func markUncapturable(_ source: CaptureSource) {
        pipeline.markUncapturable(source)
    }

    /// Photographs every running application. See
    /// ``RemoteCommand/refreshSourceThumbnails``.
    func refreshSourceThumbnails() {
        pipeline.refreshSourceThumbnails()
    }

    /// A still of what is being streamed. See ``CapturePipeline/snapshot(maxWidth:)``.
    func snapshot(maxWidth: Int) async -> CGImage? {
        await pipeline.snapshot(maxWidth: maxWidth)
    }

/// Applies a stream-quality change requested by the client.
///
/// The client's figure is remembered rather than applied blindly, because there are two numbers here
/// and only one of them is the client's to choose. See ``effectiveBitrateKbps``.
    func setStreamQuality(fps: Int, bitrateKbps: Int) {
        guard bitrateKbps > 0 else { return }
        lock.withLock { requestedBitrateKbps = bitrateKbps }
        pipeline.setBitrate(effectiveBitrateKbps * 1000)
    }

/// Moves video between the transport the client prefers and the control channel.
///
/// Both the request and the refusal are the client's to make and the host's to judge. The host knows
/// two things the client cannot: whether it has been producing frames at all, and whether the connection
/// asking is the one being served. Everything else, that the picture is missing and that the control
/// channel answers, is the client's evidence. Datagrams are never acknowledged, so a blocked path and a
/// working one look identical from this side of the socket.
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
///
/// The secret comes back to the caller, which sends it inside the control channel's TLS session; this
/// object never sees the control channel and the server never sees a socket. `nil` is a refusal, and
/// there are three of them, each worth keeping apart: a client that is not the one being served (the
/// same check ``setVideoTransport`` makes), no client at all, and an allocation this Mac cannot build a
/// lane from. Every one of them leaves the session exactly as it was, on the control stream.
///
/// The lane is installed before the secret is handed back, so the first datagrams are already on their
/// way by the time the client can read one. Losing those costs a few frames of a path that is allowed
/// to lose frames; waiting for the client to confirm it has the key would cost a round trip.
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
///
/// The cap is enforced here rather than asked for. The client is told to stop raising the rate while it
/// is in fallback, but a request is not an enforcement: the preset buttons in the client's own interface
/// send a figure directly, and a client that has been capped must not be able to undo it by tapping
/// "High". Video on the control channel shares the link that carries input, so the ceiling holds
/// whatever either end says.
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
                self.lock.withLock { self.currentSource = nil }
            }
        }
        streamer.detach()
        onSourceChanged?(nil)
        onInputTransform?(nil)
    }

    /// Diagnostics for the host window.
    var statistics: CapturePipeline.Statistics { pipeline.statistics }
    var streamStatistics: VideoStreamer.Stats { streamer.stats }

    // MARK: - Frame flow

    /// An encoded frame, on VideoToolbox's thread.
    private func deliver(_ encoded: EncodedFrame) {
// The stream has proved it is alive, so the start-window watchdog has nothing left to prove. Later
// silence is not its business, see ``watchdog``.
        cancelWatchdog()

        let prepared = adapter.adopt(encoded)

        if let config = prepared.config {
// A frame established or changed the description. Which of the two it is decides the call: a first
// description is what a waiting client was waiting for, while a later one means an attached client's
// decoder is now holding parameter sets for a picture that no longer exists.
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
    }
}

extension CaptureSource {
/// A short description for the host window. The raw values are meaningless on screen: a display is a
/// number, and a window is worse.
    fileprivate var description: String {
        switch self {
        case .display(let id): return "display \(id)"
        case .application(let pid): return "application \(pid)"
        case .window(let id): return "window \(id)"
// The count rather than the tiles: this ends up in status lines a person reads, and six window numbers
// is a sentence nobody can hold.
        case .mosaic(let layout): return "a mosaic of \(layout.tiles.count) sources"
        }
    }
}
