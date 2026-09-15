import CoreGraphics
import Foundation
import RemoteCore
import os

private let coordinatorLog = Logger(subsystem: "pl.dmq.peering.host", category: "video")

/// Owns the capture → encode → send chain, start to finish.
///
/// **Deliberately not `@MainActor`.** Frames arrive up to sixty times a second from
/// VideoToolbox, and routing each one through the main actor would put the video path behind
/// whatever SwiftUI happens to be doing — the one place in this app where a busy main thread
/// is visible to the user as stutter rather than as a delay. `HostModel` keeps the
/// main-actor state the window needs; everything below it lives here, and the only things
/// that cross back are status strings and failures.
///
/// It exists as a type rather than as more code in `HostModel` because of one ordering rule
/// that is easy to get wrong and impossible to see when it is: **a client cannot be sent a
/// frame before it has been sent the description needed to decode that frame.** Parameter
/// sets live in the encoder's format description, which does not exist until the encoder has
/// produced its first frame — so a video connection cannot be served immediately on arrival.
/// It has to wait for a keyframe, and this is where that wait is kept.
final class VideoCoordinator: @unchecked Sendable {
    private let pipeline: CapturePipeline
    private let streamer: VideoStreamer
    private let adapter = CaptureFrameAdapter()
    private let lock = NSLock()

    /// A client that has connected but cannot be attached yet, because no frame carrying
    /// parameter sets has arrived. Held as a peer rather than a flag so the attach goes to
    /// the connection that is actually waiting, not to whichever one connected most
    /// recently.
    private var waiting: PeerConnection?
    /// The peer the streamer is currently serving. Kept here as well as in `VideoStreamer`
    /// so connection lifetime and capture lifetime can be changed under one lock.
    private var attached: PeerConnection?
    private var currentSource: CaptureSource?

    /// Every accepted replacement or relevant close advances this value. Capture operations
    /// carry the value they were scheduled under, so work for an old peer can be discarded
    /// without confusing it with the peer that replaced it.
    private var audienceGeneration: UInt64 = 0

    /// Capture start/stop calls are asynchronous, but their ordering is user-visible. The
    /// task chain makes them land in the same order as the connection changes recorded under
    /// `lock`: in particular, an idle stop always finishes before a replacement peer's start.
    private var lifecycleTail: Task<Void, Never>?

    /// Whether ``currentSource`` is a decision a client made, as opposed to the default the
    /// host fell back to.
    ///
    /// The two are not interchangeable even when they name the same source, because they have
    /// different lifetimes: a default belongs to the host and outlives everyone, while a
    /// choice belongs to the client that made it and goes away with it.
    private var sourceWasChosen = false

    /// Fires if capture starts and then produces nothing at all.
    ///
    /// **This exists because the failure it catches is otherwise invisible.** Without Screen
    /// Recording permission, `SCShareableContent` still hands back a catalogue — the
    /// metadata is not what needs permission — the content filter still builds, and
    /// `startCapture` still returns without error. Then no frames ever arrive. Nothing
    /// throws, nothing logs, and the host window says "Capturing Built-in Retina Display"
    /// while the client shows a black rectangle. It is the single worst failure mode in this
    /// app and it is completely silent.
    ///
    /// It covers the *start* window only, and that restriction is what makes it correct
    /// rather than noisy. A static screen also produces no frames — ScreenCaptureKit reports
    /// `.idle`, meaning "nothing changed" — but a static screen still delivers its first
    /// frame. So "no frame has *ever* arrived" distinguishes a dead stream from a still one,
    /// and a later silence is left alone because it is not evidence of anything.
    private var watchdog: DispatchWorkItem?

    /// How long capture may go without producing a single frame before it is called dead.
    /// Generous: the first frame has to survive encoder creation and a stream start, and a
    /// false accusation here sends the user to System Settings for no reason.
    private static let firstFrameGrace: TimeInterval = 5

    /// Called for anything the user should see in the host window. `@Sendable` because this
    /// fires from the capture queue, not the main actor.
    var onStatus: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (CaptureError) -> Void)?

    /// The mapping from client coordinates to screen points for the active source, sent
    /// whenever it can change.
    ///
    /// It is re-published on every source start rather than computed once, because it
    /// depends on the source: a display maps through the display's bounds, while a window or
    /// an application maps through wherever that content happens to be. Nil means nothing is
    /// being captured and the caller should fall back to the display it is looking at.
    var onInputTransform: (@Sendable (InputTransform?) -> Void)?

    /// Called with the source list whenever it changes. The host pushes it to clients so
    /// their picker offers what actually exists right now, rather than what existed when
    /// they connected.
    var onCatalog: (@Sendable (CaptureCatalog) -> Void)?

    init(pipeline: CapturePipeline) {
        self.pipeline = pipeline

        // The streamer asks for a keyframe when a client attaches and whenever the
        // description changes, because both invalidate every frame the client's decoder is
        // holding. Routing that through the pipeline is what turns it into a real keyframe;
        // without it the client waits out the encoder's two-second interval.
        let streamer = VideoStreamer { [weak pipeline] in
            pipeline?.requestKeyframe()
        }
        self.streamer = streamer

        pipeline.onFrame = { [weak self] encoded in
            self?.deliver(encoded)
        }
        pipeline.onGeometry = { [weak self] geometry in
            guard let self else { return }
            // Only the sources whose content moves on its own. A display's geometry is fixed for
            // the life of the stream and the answer read when capture started is already exact,
            // so passing it along would rewrite the same value sixty times a second. See
            // ``CaptureSource/contentMovesOnItsOwn``.
            guard self.source?.contentMovesOnItsOwn == true else { return }
            self.onGeometry?(geometry)
        }
        pipeline.onFailure = { [weak self] error in
            self?.onFailure?(error)
        }
    }

    /// Where the captured content currently sits, for mapping client input. Nil until a
    /// frame has reported it.
    var onGeometry: (@Sendable (FrameGeometry) -> Void)?

    /// What is being streamed now, or `nil` when nothing is.
    ///
    /// Reported rather than pulled, because the answer changes for reasons the window never
    /// sees — a client asking for a different screen, the last client leaving, a source going
    /// away — and it is decided on the lifecycle queue while the window is read on the main
    /// actor. ``source`` below answers the same question, but only to a caller who already
    /// knows when to ask.
    var onSourceChanged: (@Sendable (CaptureSource?) -> Void)?

    var isSending: Bool { streamer.isAttached }

    /// The capture source being captured, if any.
    var source: CaptureSource? { lock.withLock { currentSource } }

    // MARK: - Video clients

    /// A client has opened a video connection, and the host has already checked that a live
    /// authorized control session belongs to the same key. Called on the server queue.
    func handleVideoConnection(_ peer: PeerConnection) {
        // Weak, because the connection owns this closure. A strong capture would keep the
        // connection alive for as long as the streamer holds the peer — which is exactly the
        // leak that makes a disconnected client keep receiving frames.
        peer.onClose = { [weak self, weak peer] _ in
            guard let peer else { return }
            self?.videoPeerClosed(peer)
        }

        let config = adapter.config
        lock.withLock {
            audienceGeneration &+= 1
            if config == nil {
                waiting = peer
            } else {
                // A described stream can attach immediately. It supersedes any peer that
                // was still waiting for that description when this connection arrived.
                waiting = nil
                attached = peer
            }
            scheduleEnsureCapturingLocked(generation: audienceGeneration)
        }

        if let config {
            // The description is already known from a previous client or an earlier frame,
            // so there is nothing to wait for. The attach itself asks for a keyframe, which
            // is what gives this client a picture it can decode without waiting out the
            // encoder's interval.
            streamer.attach(peer, config: config)
        }
    }

    private func videoPeerClosed(_ peer: PeerConnection) {
        let wasAttached = lock.withLock { () -> Bool? in
            let wasWaiting = waiting === peer
            let wasAttached = attached === peer
            guard wasWaiting || wasAttached else { return nil }

            if wasWaiting { waiting = nil }
            if wasAttached { attached = nil }
            audienceGeneration &+= 1

            // A source choice belongs to the departed audience. Clear it synchronously so a
            // replacement queued behind the stop selects the host's default source.
            sourceWasChosen = false
            scheduleStopIfIdleLocked(generation: audienceGeneration)
            return wasAttached
        }

        guard let wasAttached else { return }
        if wasAttached {
            // Only if this connection is the one being served. See `detach(ifAttachedTo:)`.
            _ = streamer.detach(ifAttachedTo: peer)
        }
        if wasAttached {
            coordinatorLog.notice("video client disconnected")
        } else {
            coordinatorLog.notice("waiting video client disconnected")
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

    private func scheduleEnsureCapturingLocked(generation: UInt64) {
        scheduleLifecycleLocked { [weak self] in
            guard let self, self.hasAudience(generation: generation) else { return }
            do {
                try await self.ensureCapturing()
                guard self.hasAudience(generation: generation) else { return }
                // If capture had to be started for this connection, the attach above asked
                // for a keyframe before there was an encoder to hear it.
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
                return self.audienceGeneration == generation
                    && self.waiting == nil && self.attached == nil
            }
            self.onInputTransform?(nil)
            if remainsIdle {
                self.onStatus?("Capture stopped · no video clients")
                coordinatorLog.notice("capture stopped · no video clients")
            }
        }
    }

    private func hasAudience(generation: UInt64) -> Bool {
        lock.withLock {
            audienceGeneration == generation && (waiting != nil || attached != nil)
        }
    }

    private func isIdle(generation: UInt64) -> Bool {
        lock.withLock {
            audienceGeneration == generation && waiting == nil && attached == nil
        }
    }

    // MARK: - Catalogue

    /// Re-reads the source list and offers it to ``onCatalog``.
    ///
    /// Called when a client connects, and again whenever the resolver reports the list may
    /// have changed. Reading it needs Screen Recording permission, so this is also the point
    /// at which a client can be told the list is unavailable — but a failure here is not
    /// worth interrupting anyone over: the picker is a convenience, and a client that never
    /// receives a catalogue is still served the default display.
    func refreshCatalog() {
        Task { [weak self] in await self?.pushCatalog() }
    }

    private func pushCatalog() async {
        do {
            let catalog = try await pipeline.catalog()

            // Offered every time, with no "unchanged, skip it" check here. That check used
            // to live at this level and it was a bug: the resolver invalidates on every
            // application launch and quit, and most of those do leave the list unchanged, so
            // suppressing repeats looked like an easy win. But a host-wide "last catalogue"
            // cannot tell *which* client already has it, so it answered "nobody needs this"
            // for every client that had not connected yet — the first client suppressed the
            // push for all the others, and every later client got an empty source picker.
            //
            // The suppression is still wanted; it just belongs where the knowledge is.
            // Each ``HostSession`` remembers what it has already sent and drops a repeat, so
            // an unchanged list never rebuilds a picker that is already on screen, while a
            // client that has been told nothing is always told.
            onCatalog?(catalog)
            // The Space count and preview count are the only way to tell a host that has never
            // seen a desktop from one that has: both send the same picker, and the difference
            // is a screenshot that either happened or was refused.
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
    /// `CGMainDisplayID()` is safe to call without Screen Recording permission — it reports
    /// which display the cursor is on, not what is on it — so this can be computed before
    /// the permission question is even asked.
    static var defaultSource: CaptureSource {
        .display(UInt32(CGMainDisplayID()))
    }

    /// Starts capturing if nothing is, or if what is being captured is a decision nobody is
    /// left to have made.
    ///
    /// The question is deliberately not "is anything being captured". A stream left running
    /// on a departed client's source is still running, and answering the narrow question is
    /// what let it be shown to the next client — see ``forgetChosenSourceIfIdle()``.
    ///
    /// The default is not restarted when it is already running, which is every client after
    /// the first on an untouched host. That restart would be a few hundred milliseconds of
    /// black for no change in the picture: `startCapture` rebuilds the `SCStream` rather than
    /// reusing it, so an unnecessary call is not free.
    private func ensureCapturing() async throws {
        let target = lock.withLock { () -> CaptureSource in
            guard let current = currentSource, sourceWasChosen else { return Self.defaultSource }
            return current
        }
        guard lock.withLock({ currentSource }) != target else { return }
        try await startCapture(target)
    }

    /// Switches what is being captured.
    ///
    /// **The video connection survives; the capture stream does not.** `switchSource` goes
    /// through ``startCapture(_:)``, which stops the running `SCStream` and builds a new one
    /// for the new source — it does not call `SCStream.updateContentFilter(_:)`, which would
    /// swap the filter underneath a live stream. That is a deliberate trade rather than an
    /// oversight: an in-place filter swap still owes the client a fresh keyframe and still
    /// leaves the encoder holding a surface of the old size, so it would save the stream
    /// setup and nothing else, while adding a second code path whose failure mode is a
    /// stream that keeps producing frames in the wrong shape. Rebuilding costs a few hundred
    /// milliseconds of black and reuses the one path that is already exercised.
    ///
    /// The client sees no reconnect either way: the new surface produces new parameter sets,
    /// the adapter reports that as a description change, the streamer re-sends the config and
    /// forces a keyframe, and the client rebuilds its decoder against the new picture.
    func switchSource(_ source: CaptureSource) async throws {
        let operation = lock.withLock { () -> Task<Void, Error> in
            // Recorded before the switch, not after. If the capture fails, the *intent* is
            // still the client's. Scheduling under the same lock also orders a disconnect
            // after this switch, rather than letting its stop race the pipeline start.
            sourceWasChosen = true
            let previous = lifecycleTail
            let operation = Task { [weak self] in
                if let previous { await previous.value }
                guard let self else { return }
                try await self.startCapture(source)
            }
            lifecycleTail = Task { _ = await operation.result }
            return operation
        }
        try await operation.value
    }

    private func startCapture(_ source: CaptureSource) async throws {
        try await pipeline.start(source: source)
        lock.withLock { currentSource = source }
        onSourceChanged?(source)
        onInputTransform?(pipeline.inputTransform())
        armWatchdog(source: source)
        onStatus?("Capturing \(source.description)")
        coordinatorLog.notice("capture started · \(source.description, privacy: .public)")
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

    /// Capture started and then produced nothing. Ask the system which of the two causes it
    /// is, rather than guessing: the remedy is completely different, and one of them is a
    /// button the user has to press in System Settings.
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

        // Frames that carry no picture are still frames, and a stream reporting them is
        // working: it is delivering on schedule and the screen is not changing. The two
        // counters together are what tell the difference, and they are the reason
        // ``CaptureEngine`` counts both — treating "no picture frames" as death would
        // accuse a healthy stream of being dead and send the user to System Settings over
        // a still screen.
        //
        // Worth knowing that this signature has a second cause: a frame-status reader that
        // answers `nil` for every frame puts the stream in exactly this state, alive at full
        // rate with nothing ever delivered. If this branch ever becomes the normal case
        // rather than a rare one, the counters above are the tell — the status read is the
        // first thing to check, and it is the one bug in this pipeline that looks from the
        // outside like a denied Screen Recording permission.
        if stats.idleSamples > 0 && stats.framesDelivered == 0 {
            onStatus?("Capturing \(source.description) · nothing new to send yet")
            return
        }

        guard permission else {
            onFailure?(.screenRecordingDenied)
            return
        }

        // Permission is fine, so the stream itself is the problem. Say what was being
        // captured and that permission was not the reason — otherwise the next person to
        // read this goes looking in System Settings for something that is already correct.
        onFailure?(.streamFailed(
            "Capture started but produced no frames from \(source.description), and Screen "
                + "Recording permission is granted. The source may have gone away."
        ))
    }

    /// Applies a stream-quality change requested by the client.
    /// Re-photographs the desktop showing on each display. See
    /// ``RemoteCommand/refreshSpacePreviews``.
    func refreshSpacePreviews() {
        pipeline.refreshSpacePreviews()
    }

    func setStreamQuality(fps: Int, bitrateKbps: Int) {
        if bitrateKbps > 0 {
            pipeline.setBitrate(bitrateKbps * 1000)
        }
    }

    func stop() {
        // Before anything else: a teardown must not be reported as a failure to capture.
        cancelWatchdog()
        lock.withLock {
            currentSource = nil
            waiting = nil
            attached = nil
            sourceWasChosen = false
            audienceGeneration &+= 1
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
        // The stream has proved it is alive, so the start-window watchdog has nothing left
        // to prove. Later silence is not its business — see ``watchdog``.
        cancelWatchdog()

        let prepared = adapter.adopt(encoded)

        if let config = prepared.config {
            // A frame established or changed the description. Which of the two it is decides
            // the call: a first description is what a waiting client was waiting for, while a
            // later one means an attached client's decoder is now holding parameter sets for
            // a picture that no longer exists.
            let pending = lock.withLock { () -> PeerConnection? in
                guard let pending = waiting else { return nil }
                waiting = nil
                attached = pending
                return pending
            }
            if let pending {
                streamer.attach(pending, config: config)
            } else if streamer.isAttached {
                streamer.updateConfig(config)
            }
        }

        // Submitted unconditionally, including while nothing is attached: the streamer owns
        // the decision to buffer or drop, and a frame the host chose not to send is not a
        // frame this layer should be second-guessing.
        streamer.submit(prepared.frame)
    }
}

extension CaptureSource {
    /// A short description for the host window. The raw values are meaningless on screen —
    /// a display is a number, and a window is worse.
    fileprivate var description: String {
        switch self {
        case .display(let id): return "display \(id)"
        case .application(let pid): return "application \(pid)"
        case .window(let id): return "window \(id)"
        }
    }
}
