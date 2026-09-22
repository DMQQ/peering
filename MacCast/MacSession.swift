import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import os

private let sessionLog = Logger(subsystem: "pl.dmq.peering", category: "session")

/// One Mac, connected.
///
/// **The unit the app is being rearranged around.** Everything that describes a single Mac —
/// its phase, its wire, its picture, its shells, its folders, the record of the time spent on
/// it — lives here rather than on ``SessionModel``, so that a second Mac can exist without the
/// two sharing a phase or a terminal list. ``SessionModel/sessions`` holds these; today it can
/// only ever hold one.
///
/// **It is a part of the model, not a peer of it.** The app-wide things a session needs, and
/// cannot own — the plan the user bought, the store the history is filed in, the paywall, the
/// renderer every session draws through — are reached through ``model``. That reference is
/// `unowned` because the ownership runs the other way and is total: a session is created by the
/// model and its life ends with the model's. See ``SessionModel/connect(to:)``.
@Observable
@MainActor
final class MacSession: Identifiable {
    /// Which way the control connection is being carried.
    ///
    /// **Declared in ``MacCastKit`` and merely named here**, like ``StreamQuality``: the cases
    /// and what a finished record makes of each are storage policy, and there is a test for the
    /// mapping that runs without an app bundle. Per Mac rather than per app, because the answer
    /// genuinely differs between two Macs at the same moment: one can be on this network while
    /// the other is on the other side of the country, and the picture ceiling differs between
    /// them. See ``videoCeiling``.
    typealias ConnectionPath = MacCastKit.ConnectionPath

    /// The same three cases in the card's spelling.
    ///
    /// Mapped rather than shared because the raw values differ on purpose: this one is shouted
    /// at a diagnostics panel, and the card's is set in a chip beside a sentence. A single enum
    /// serving both would have to be named for one of them.
    static func activityPath(_ path: ConnectionPath?) -> SessionActivityAttributes.Path? {
        switch path {
        case .lan: return .lan
        case .relay: return .relay
        case .direct: return .direct
        case nil: return nil
        }
    }

    // MARK: - Identity

    /// This session's own identity, which is what ``SessionModel/activeSessionID`` names.
    ///
    /// Not the Mac's ID: a Mac can be connected to twice over the life of a launch (a drop, a
    /// reconnect), and the tab strip has to be able to tell one of those apart from the other.
    /// It is also not a host ID, which is not known at all until the handshake arrives.
    let id = UUID()

    /// The app-wide half of the session, which this is a part of.
    unowned let model: SessionModel

    /// The one decoder every session draws through.
    ///
    /// **Shared on purpose.** A session is a connection, and a renderer is the expensive thing a
    /// connection feeds; giving each one its own would mean two hardware decoders running for
    /// one pair of eyes, which is the cost this whole arrangement exists to avoid.
    @ObservationIgnored let renderer: VideoRenderer

    init(model: SessionModel, renderer: VideoRenderer) {
        self.model = model
        self.renderer = renderer
    }

    // MARK: - Connection state

    var phase: ClientSession.Phase = .idle

    /// The wire. `nil` between the end of one attempt and the start of the next.
    var wire: ClientSession?

    /// The Mac's own device ID, once the handshake has said what it is.
    var hostID: String?

    /// What the Mac calls itself, or what it was dialled as before the handshake.
    var hostName: String?

    /// The quality the user is set to, as this session reads it.
    ///
    /// **On the session, not on the app, though the choice is stored app-wide.** What the Mac
    /// is told depends on this session's path and this session's plan — see ``videoCeiling`` —
    /// so the number that reaches the wire is per Mac even though the preference behind it is
    /// not. The preference itself is ``SessionModel/streamQuality``.
    var connectionPath: ConnectionPath?
    var usedDirectPath = false
    var directPathStatus: ClientSession.DirectPath = .notTried

    /// What the relay's datagram lane carried, kept after the session ends.
    ///
    /// Kept rather than cleared, like ``directPathStatus`` beside it and for the same reason:
    /// Settings cannot be opened while a session runs, so the only moment anybody can read this
    /// is just after one, which is exactly when it is worth reading. A session with no datagram
    /// lane, on the LAN or on the relay's control channel, leaves it `nil` rather than zeroed.
    var datagramCounts: ClientSession.DatagramCounts?

    /// Round trip of the control channel, which goes through the relay in every session.
    var latencyMilliseconds: Double?

    /// Round trip of the lane the picture is arriving on, and whether that lane is the direct one.
    ///
    /// **The figure worth showing, and the reason it exists separately.** ``latencyMilliseconds``
    /// is the relay's even when the picture found a path of its own, because the control
    /// connection carries input and always goes the long way. `nil` until a datagram lane exists,
    /// which is most sessions at their start and some for their whole life.
    var pathLatencyMilliseconds: Double?
    var pathLatencyIsDirect = false

    /// The one number the status chip shows.
    ///
    /// The picture's round trip when there is a lane to measure it on, and the control channel's
    /// otherwise — which is not a fallback but the honest answer in that case: with no datagram
    /// lane the picture is on the control channel, so its round trip is the picture's.
    var shownLatency: Double? { pathLatencyMilliseconds ?? latencyMilliseconds }

    /// When the session that is up now came up, for the elapsed-time readout.
    ///
    /// A `Date` and not a counter: the view formats it with `Text(_:style:.timer)`, which the
    /// system advances on its own. A `Timer` here would wake the main actor once a second to
    /// update a number that the screen can already count by itself.
    var sessionStartedAt: Date?

    /// Whether this connection ever reached a Mac.
    ///
    /// Kept for the one question the phase cannot answer: a dropped session and a session that
    /// never got past the handshake are both `.failed`, and only the first is one the ladder
    /// should keep trying to put back. See ``resumeIfNeeded()``.
    var hasBeenReady = false

    /// Optimistic state for this session's physical-display privacy command. The host always
    /// restores brightness when the last client disconnects.
    var privacyModeEnabled = false

    // MARK: - The picture

    var catalog: CaptureCatalog?
    var activeSourceID: String?
    var picture: PictureIdentity?

    /// Something the Mac wants said about the picture, or `nil`.
    ///
    /// Kept apart from `videoStatus`, which describes the *stream*. This describes the Mac
    /// behind a perfectly healthy stream: the frames are arriving on time and every one of
    /// them is black, because the screen they are of is asleep. From the phone those two look
    /// identical, and only the Mac knows which it is.
    var remoteNotice: NoticePayload?
    var videoStatus = "No video stream"

    /// The frames per second arriving, as measured by the last two polls — see
    /// ``updateFrameRate(from:)``. Zero until there have been two samples to compare.
    var videoFramesPerSecond: Double = 0

    /// The frame count and the moment it was read, for the difference above.
    var lastFrameSample: (count: Int, at: Date)?

    /// True while the video channel is delivering frames (not ended/absent).
    var isVideoStreaming = false

    /// Which channel the picture is arriving on. `.control` means the Mac's network is not
    /// letting video through and the session has fallen back — see ``VideoFallbackPolicy``.
    var videoTransport: VideoTransport = .primary

    var videoPoll: Task<Void, Never>?
    /// The task inside the current attempt, retained so a user ending or replacing the session
    /// also cancels an in-flight relay WebSocket rather than only the TCP socket it may create.
    var connectTask: Task<Void, Never>?

    /// Whether the *user* asked for this session to end, read and cleared by the transition that
    /// follows.
    ///
    /// **Per Mac, where this was one flag on the container, and that was a bug rather than a
    /// tidiness.** A dropped link and a deliberate end arrive as the same phase, so intent has to
    /// be carried across rather than worked out afterwards; it is then read and cleared by the
    /// first transition to see it. Ending one Mac is one transition and one flag, which is why one
    /// shared flag went unnoticed for so long. `disconnect()` ends every Mac at once, and each one
    /// answers with its own transition: the first consumed the flag, and every Mac after it was
    /// read as having *dropped*, so its reconnect ladder armed, `isReconnecting` stuck true, and
    /// the Mac stayed in the strip as a tab that never came back.
    ///
    /// The banner is untouched by this. Whether the end was the user's or iOS's is still decided
    /// once by the caller and handed to every session that ends, so the Macs cannot disagree about
    /// it; what is per-session is the record of the decision, because the ladder reads it later and
    /// there is no later left for a single record to serve two Macs.
    var userEndedDeliberately = false

    /// Takes this Mac's connection apart, and leaves the object for its last figures to be read.
    ///
    /// **Not a disconnect of its own**: whether the end was the user's or iOS's is decided once by
    /// the caller and said once in the banner. What it takes is the caller's answer, kept for the
    /// transition that follows. See ``userEndedDeliberately``.
    ///
    /// The record is filed first, because everything it describes — the path, the name, the
    /// bytes — is cleared below. The player is released rather than kept: its `deinit` stops the
    /// engine, and holding one past its session leaves an audio engine running for a Mac nobody
    /// is connected to.
    func endSession(deliberate: Bool) {
        userEndedDeliberately = deliberate
        finishSessionHistory()
        connectTask?.cancel()
        connectTask = nil
        stopReconnecting()
        wire?.disconnect()
        wire = nil
        videoPoll?.cancel()
        videoPoll = nil
        audioPlayer = nil
        connectionPath = nil
        sessionStartedAt = nil
        picturePaused = false
        phase = .disconnected
    }

    // MARK: - Coming back after a drop

    /// Whether there is a live connection behind this session, or an attempt to put one back.
    ///
    /// **The question the strip, the ceiling and the gate all ask**, and deliberately not
    /// `phase.holdsSession` on its own: a Mac that has dropped and is being retried is a Mac the
    /// user still has open, and letting go of it the moment its socket failed is how a session
    /// disappears from the app while the ladder is quietly rebuilding it.
    ///
    /// **A Mac that has never been connected is not that Mac, which is what `hasBeenReady` is doing
    /// in a question about liveness.** A dial that failed before its handshake arms the same ladder
    /// (the failure card promises a few more attempts, and they are worth making), but nothing was
    /// ever open, and counting it as an open Mac is how a Mac that was merely unreachable came to
    /// be reported as a second one. The free plan's one-Mac allowance was spent by an attempt, so
    /// the Connect row for that same Mac went behind ``PlanCapability/concurrentSessions`` and the
    /// way past it was to buy a plan for a Mac that had never answered. ``SessionModel/isBusy`` asks
    /// the same list, so the picker's other rows were dead for the length of the ladder too.
    ///
    /// The flag survives the ladder's own dial (see ``SessionModel/reconnect(_:to:)``), so a Mac
    /// that really did drop and is being put back is still live for the whole of its ladder.
    var isLive: Bool { phase.holdsSession || (hasBeenReady && isReconnecting) }

    /// Whether this Mac dropped and is being put back, rather than being opened for the first time
    /// or dialled again by hand.
    ///
    /// **The one question neither the phase nor ``isLive`` can answer.** A network switch and a
    /// first connection both pass through `phase.holdsSession` and both run the same ladder, so
    /// those two say the same thing about either. What separates them is that this Mac has been
    /// ready before and the user did not end it, which is why ``hasBeenReady`` has to survive the
    /// dial that ``SessionModel/connect(to:replacing:)`` makes, and why it is carried there.
    ///
    /// **`hasGivenUpResuming` is here because the phases cannot tell two moments apart.** The
    /// instant a drop lands, and the instant the ladder finally runs out, the session is in the
    /// same state: `.failed`, `isReconnecting` false, a Mac that had been ready. The first of those
    /// is a resume about to be armed and the second is a resume that has ended, so "an attempt is
    /// in flight" is not the question, and asking it either way would put the connecting theatre
    /// back on screen for a network blip or leave a dead session's picture up for ever. The answer
    /// is a fact worth storing rather than a state worth inferring.
    ///
    /// Everything that should behave differently for a blip than for a connection keys off this:
    /// the remote screen staying up rather than handing over to the picker, the connecting card
    /// staying down, the failure banner staying quiet, and the shorter ladder.
    ///
    /// The rule itself lives in ``SessionResume``, where it can be tested: it takes five facts and
    /// the phases are two of them, which is not obvious enough to leave unverified.
    var isResumingAfterDrop: Bool {
        SessionResume.isUnderWay(
            hasBeenReady: hasBeenReady,
            userEndedDeliberately: userEndedDeliberately,
            hasGivenUpResuming: hasGivenUpResuming,
            isReconnecting: isReconnecting,
            phase: phase
        )
    }

    /// Set when the retry ladder runs out, so that a Mac which is not coming back stops being
    /// treated as one that is. Cleared the moment a session is up again.
    var hasGivenUpResuming = false

    /// Set while a dropped session is being put back, so the Live Activity can say so rather
    /// than keep claiming a connection that is not there.
    var isReconnecting = false

    /// How many attempts this Mac's ladder has made, and the task waiting to make the next one.
    ///
    /// **Per Mac, which is the whole reason these moved here.** Two Macs on one phone drop for
    /// two different reasons at two different times, and a shared counter means the second Mac's
    /// failure resets the first one's backoff, so a Mac that is switched off is dialled every
    /// second forever because the Mac in the user's hand keeps failing too.
    var reconnectAttempt = 0
    var reconnectTask: Task<Void, Never>?

    /// Puts this Mac back, if it dropped and the user did not end it.
    ///
    /// **This Mac and no other**, which is what the ladder being here is for. The host is known —
    /// it is the one this session was dialled for — so the resume is a dial to a named Mac rather
    /// than "whatever was open last", and a second Mac dropping at the same moment runs its own
    /// ladder beside this one without either resetting the other's backoff.
    ///
    /// The wire is the evidence that an attempt is already in flight, and it is assigned
    /// synchronously in ``SessionModel/connect(to:)`` before the phase has heard anything, while
    /// the browser fires on its own schedule. Without that guard the retry and the browser can
    /// both start one, and each silently closes the other's connection.
    func resumeIfNeeded() {
        guard wire == nil, !phase.holdsSession else {
            if phase.holdsSession { stopReconnecting() }
            return
        }
        // **Only a Mac that was actually connected.** A connection that failed at the handshake,
        // or a first pairing with a mistyped ID, is an attempt that has ended rather than a
        // session waiting to come back, and retrying it forever is what the failure card is for.
        guard hasBeenReady || isReconnecting else { return }
        guard UserDefaults.standard.bool(forKey: SessionModel.resumeKey) else {
            // **Nothing is going to put this Mac back, so it stops claiming that one will.** This
            // switch is the user's own answer to "resume when reachable", and a ladder that armed
            // itself and then found the answer was no left `isReconnecting` set with no task behind
            // it. That is a session the app has no way to finish: live by its own definition, with
            // nothing left that will ever clear the flag, so the Mac holds a session slot and a tab
            // for the rest of the launch and cannot be opened again. Turning the switch off is not
            // meant to cost a Mac.
            stopReconnecting()
            return
        }
        guard let hostID else {
            // A connection that never reached a handshake has no Mac to dial. That is the case
            // for a first pairing whose ID was mistyped, and there is nothing to retry.
            stopReconnecting()
            return
        }

        if let host = model.hosts.first(where: { $0.id == hostID }) {
            stopReconnecting()
            model.isResuming = true
            model.reconnect(self, to: .discovered(host))
        } else if model.allowsRelay, model.pins.hostIDs.contains(hostID) {
            stopReconnecting()
            model.isResuming = true
            model.reconnect(self, to: model.relayTarget(hostID: hostID, name: hostName ?? "A Mac"))
        } else {
            // The LAN-only case: the Mac is paired and simply not here yet. The ladder keeps
            // asking until it appears, which is the whole of what "wait for it to come back"
            // means — stopping at the first attempt that found nothing would end a resume that
            // has not failed, only not succeeded yet.
            scheduleReconnect()
        }
    }

    /// Arms the next attempt, if there is one left to make.
    ///
    /// **A resume gets the shorter ladder, and it is chosen here rather than kept in the session**
    /// because it has to match the counter: `reconnectAttempt` indexes into whichever ladder is
    /// being used, and it is carried across a dial precisely so that this one can run out. A
    /// ladder that is swapped half way through would index the wrong list.
    func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delays = isResumingAfterDrop
            ? SessionModel.resumeReconnectDelays
            : SessionModel.reconnectDelays
        guard reconnectAttempt < delays.count else {
            isReconnecting = false
            // **Said out loud, because nothing else will say it.** With the banner suppressed for
            // the whole of a resume, running out is the moment the app has to stop behaving like a
            // session that is coming back: this flag is what turns the remote screen over to the
            // picker so that the failure is on screen rather than behind a frozen picture.
            //
            // The banner is not re-posted here. `SessionAwareness` refuses a repeat of the phase it
            // is already in, and the phase has been `.failed` since the drop, so the failure
            // reaches the user as the Connect screen's own card, which is the app's main way of
            // saying it.
            hasGivenUpResuming = true
            // The screen is about to leave and no replacement stream will reuse its display.
            // Non-deliberate teardown kept this attachment alive for the retry; this is the
            // terminal path that releases it. A background Mac shares the active Mac's renderer
            // and therefore must not detach it.
            if isActive { renderer.detach() }
            // The reconnect ladder gave up. `sessionMoved` is not called again because there is
            // no phase change — the phase is already `.failed` or `.disconnected` — so the Live
            // Activity has to be told directly, or it stays on "Reconnecting…" indefinitely.
            //
            // Only for the Mac on screen: a background Mac giving up is a banner, not a card.
            if isActive {
                SessionActivity.shared.sessionDropped(
                    hostName: hostName ?? "the Mac",
                    startedAt: nil,
                    path: Self.activityPath(connectionPath)
                )
            }
            return
        }
        let delay = delays[reconnectAttempt]
        reconnectAttempt += 1
        isReconnecting = true
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.resumeIfNeeded()
        }

        // **The network may already have moved, and this is the case where it usually has.** A
        // relay socket can hang for the whole of the ten seconds the silence watchdog allows, and
        // the phone's own change of network is reported long before the drop is: at a moment when
        // nothing was being put back, which is no reason to dial and so was not acted on. Asked
        // here because this is the only place a wait begins, and deferred by a turn because the
        // answer can dial: this runs inside the handling of a phase change, and the rest of that
        // handling has to finish against the session it started with.
        //
        // Only for a Mac being put back. A first connection's ladder is a wait with nothing behind
        // it to hurry.
        if isResumingAfterDrop {
            Task { @MainActor [model] in model.considerNetworkChange() }
        }
    }

    /// Stops the retry, *without* resetting the backoff. See
    /// ``SessionModel/stopReconnecting()`` for why the counter is not cleared here.
    func stopReconnecting() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
    }

    // MARK: - Asking this Mac for the picture, and for silence

    /// What this Mac said about being asked to pause. See ``PicturePause/mayAsk(hostDeclared:)``.
    ///
    /// Read off the handshake and never assumed: `false` is a Mac too old to have been asked, and
    /// the command means a dropped session on one of those rather than a picture that stops.
    var hostSupportsVideoPause = false

    /// What this Mac said about carrying a picture on the clipboard. See
    /// ``ClipboardImages/maySend(toHostDeclared:)``.
    ///
    /// Read off the handshake and never assumed, for the same reason and with a starker cost: the
    /// command that pushes a picture is one a Mac this old does not understand at all, and an
    /// unknown command is a decode failure in the middle of a session rather than a copy that
    /// quietly does nothing.
    var hostSupportsClipboardImages = false

    /// What the user put together: these windows, in this order, with these sizes.
    ///
    /// **The intent rather than the rectangles.** A layout is rectangles in a canvas of one
    /// particular shape — stale the moment the phone rotates or the viewport changes — while what
    /// the user chose is the list above. Keeping the choice and deriving the rectangles is one
    /// copy of the arrangement instead of two that can disagree. See ``MosaicGrid``.
    ///
    /// **Held per Mac and not per app**, with the same lifetime rule as the source itself: an
    /// arrangement is a place on *this* Mac, and a session that comes back to a different one
    /// must not offer to return to a mosaic of windows that are not there.
    ///
    /// It is what makes "back to the mosaic" mean anything, and it is cleared the moment a source
    /// outside the arrangement is chosen: see ``SessionModel/selectSource(_:)``. Selecting one of
    /// its tiles keeps it, because that is the gesture the back control exists to undo.
    var mosaicChoices: [MosaicChoice] = []

    /// The arrangement as the Mac is being asked for it, built from those choices.
    var mosaicLayout: MosaicLayout? {
        MosaicGrid.layout(choices: mosaicChoices, viewport: mosaicViewport)
    }

    /// The canvas a mosaic is asked for: the phone's own screen in pixels.
    ///
    /// Read from the window scene rather than from `UIScreen.main`, which is deprecated and, on
    /// a device with more than one scene, is not necessarily the one being looked at.
    var mosaicViewport: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        else {
            // No scene at all, which is a state the app cannot act in rather than a case to
            // handle: a canvas a Mac will accept, so nothing downstream has to.
            return CGSize(width: 1280, height: 720)
        }
        let bounds = scene.screen.bounds
        let scale = scene.screen.scale
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// Whether the picture on screen is that arrangement rather than one of its tiles.
    var isShowingMosaic: Bool {
        guard let mosaicLayout else { return false }
        return activeSourceID == CaptureSource.mosaic(mosaicLayout).stableID
    }

    /// What this Mac said about building a mosaic. See ``MosaicSupport/maySend(hostDeclared:)``.
    ///
    /// Read off the handshake and never assumed, which matters more here than anywhere else on
    /// this list: every other gated request that reaches an un-updated Mac is a command it cannot
    /// decode, and this one is a *capture source* it cannot decode, sent at the moment the user
    /// asks for a whole arrangement of windows. Sending it anyway ends the session.
    var hostSupportsMosaic = false

    /// Whether the picture is stopped because this client asked for it to be.
    ///
    /// **Not the same as the picture being stopped.** A Mac whose screen is asleep, a stream that
    /// failed, and a pause this end requested all look alike on screen and are three different
    /// facts; only the third is something this end may undo.
    var picturePaused = false

    /// When the picture was last asked for again, and how long it took to come back.
    ///
    /// **The number the whole feature has to be judged on.** A design whose promise is that
    /// switching Macs is instant has to be able to say how long the first frame takes after the
    /// ask, and nothing else in the app can measure it: the request goes out here and the frames
    /// come back to the renderer, so this is the only place both ends of the interval are visible.
    /// Reported into the notes and into Diagnostics rather than shown standing, because it is a
    /// fact about the plumbing and the screen is for the picture.
    var pictureResumedAt: Date?
    var pictureResumeBaselineFrames: Int?
    var lastResumeMilliseconds: Double?

    var autoQualityPolicy = AutoQualityPolicy(path: .lan)
    var lastAutoDroppedFrames = 0

    /// A note about this Mac, newest last.
    ///
    /// Per Mac, and that is the point of it moving: the notes are what the session's own log is
    /// made of, and a diagnosis of the Mac on the left of the strip must not be carrying
    /// sentences about the one on the right.
    var notes: [String] = []

    // MARK: - Session history

    var activeSessionHistoryID: UUID?
    var activeSessionHistoryStartedAt: Date?
    var activeSessionBytes: Int64 = 0
    var lastBandwidthSampleBytes: Int64 = 0
    var activeSessionLogs: [String] = []

    /// Whether this is the Mac the user is looking at.
    var isActive: Bool { model.activeSessionID == id }

    /// Whether this Mac's sound should be coming out of the phone.
    ///
    /// **Two conditions, and the second is the one several Macs added.** The switch and the plan
    /// decide whether the Mac's audio is played at all — see ``SessionModel/playsHostAudio`` — and
    /// being the Mac on screen decides whether it is *this* Mac's audio. Without the second, two
    /// Macs open at once are two audio engines decoding into one pair of ears, playing over each
    /// other, and the user has no control that separates them.
    ///
    /// The price is the decision the plan already took: a Mac behind the one on screen is silent,
    /// so a call left running on it cannot be heard. Audible background audio would be a second
    /// feature, with a second player and a way to say which Mac it belongs to, and it is not this.
    var shouldPlayAudio: Bool { isActive && model.playsHostAudio }

    /// Applies the answer above to the player this Mac has, if it has one.
    ///
    /// Called when a config arrives and again when the active Mac changes, because the two are
    /// different moments: a Mac can be switched to long after its player was built, and a player
    /// built for the Mac on screen goes on playing after the user has looked away unless it is
    /// told. Nothing here starts or stops a stream; it is the mute line and nothing else.
    func refreshAudioMuteState() {
        audioPlayer?.isMuted = !shouldPlayAudio
    }

    // MARK: - Clipboard

    /// The most recently received host clipboard. `nil` until the first pull.
    ///
    /// A payload rather than a string, so that a screenshot copied on the Mac arrives as readily
    /// as a line of text. See ``ClipboardPayload``.
    var hostClipboard: ClipboardPayload?

    /// Whether a clipboard pull is in flight.
    var clipboardPulling = false

    // MARK: - Audio

    var audioPlayer: RemoteAudioPlayer?

    // MARK: - Terminals

    var terminals: [RemoteTerminal] = []
    var selectedTerminalID: UUID?

    /// The command last sent, and when — so the shell's answer can be read against it.
    ///
    /// A PTY gives a byte stream with no marker for where one command's output starts, so the
    /// only thing that ties a message to a command is that it arrived right after one.
    var lastSentCommand: String?
    var lastSentAt: Date?

    // MARK: - File browsing

    /// Every folder the Mac has listed, keyed by the terminal it was listed for and the path it
    /// was listed at. See ``RemoteDirectoryKey``.
    ///
    /// Held rather than asked for per appearance, and that is most of what makes browsing feel like
    /// a file manager instead of a series of waits: stepping into a folder and back out of it is
    /// instant, and a folder already in hand is shown while its next copy is on the way.
    var directories: [RemoteDirectoryKey: RemoteDirectory] = [:]

    /// Which folder each terminal's browser is showing, and no entry for a browser that has not
    /// opened yet or one still waiting on the Mac's home folder to resolve to a path.
    var browsingPaths: [UUID: String] = [:]

    /// Folders asked for and not yet answered — what a spinner on the panel is reading.
    var pendingDirectories: Set<RemoteDirectoryKey> = []

    /// Why a folder could not be listed, until it lists.
    var browseFailures: [RemoteDirectoryKey: String] = [:]

    /// The file being shown, and how much of it has arrived. One at a time because only one can be
    /// on screen — opening another replaces it.
    var filePreview: RemoteFilePreview?

    /// A command waiting for the shell that will run it.
    ///
    /// Running a file opens a terminal of its own, and a terminal has no id until the Mac answers
    /// that it made one — so the command cannot be sent when the button is tapped, only remembered
    /// until ``apply(terminal:)`` sees the shell arrive. One at a time, because the second tap in
    /// the moment before the first shell exists means to run the second file, not both, and a queue
    /// would be a promise about ordering that nothing here needs to make.
    var pendingRun: String?

    /// A file on its way to the Mac, and which door it came through.
    struct FileWrite: Equatable {
        /// Whether the file is an editor's text or one the user picked.
        ///
        /// The two are answered differently and are the same operation: a save reads the file back,
        /// so the editor shows what is on disk rather than what was sent; an upload asks for the
        /// folder again, so the new file appears in the list. Everything else about them (the
        /// chunking, the size cap, the refusal, the failure) is shared, which is why they share a
        /// record rather than two dictionaries that would have to be kept in step.
        enum Door { case save, upload }

        let door: Door
        /// The file being written. What the Mac's answer is matched on, since it names the file it
        /// wrote, and what says which folder to ask for again after an upload.
        let path: String
    }

    /// Files on their way to the Mac, by the terminal they are being written through.
    ///
    /// By terminal rather than one flag, because two can be in the air at once: a user who starts
    /// an upload and then switches to another shell and edits a file there has two transfers
    /// running, and a single flag hands the first answer to arrive to whichever of them asked
    /// second. The Mac keeps its own half keyed the same way, for the same reason.
    var writes: [UUID: FileWrite] = [:]

    /// Why a write did not land, by the terminal it was made through, and kept apart by door.
    ///
    /// Apart, because the two are fixed differently and say so differently: a save that failed is a
    /// file to correct, an upload that failed is a file to choose again. Read through
    /// ``saveFailure(sessionID:)`` and ``uploadFailure(sessionID:)`` so the panel asks about the
    /// terminal it is drawing rather than about whichever wrote last.
    var saveFailures: [UUID: String] = [:]
    var uploadFailures: [UUID: String] = [:]

    /// Something being made, renamed or removed on the Mac, and which folder to ask about after.
    struct FileChange: Equatable {
        /// What is being asked for. Held rather than only the path, because the answer says what
        /// happened but not what was *asked*, and the path a rename moves is built from both.
        let operation: RemoteFileOperation
        /// The path the request named — the file's own path for a rename, not the one it becomes.
        /// What the Mac's answer is matched on, since it echoes back what it was sent.
        let path: String
    }

    /// Folders being sent to the Mac, by the terminal they are being sent through.
    ///
    /// **A folder is a sequence of the operations beside it, not a kind of its own.** The Mac
    /// already answers "make a folder" and "write this file", so this is the phone's own walk of
    /// its filesystem followed by a series of requests the far end has understood since it learned
    /// to change a listing. Nothing about the protocol knows a folder is involved.
    ///
    /// One per shell, for the reason the writes and the changes are: the Mac answers an operation by
    /// naming the path it was given, and two operations through one shell are two answers that could
    /// both match one remembered request.
    var folderUploads: [UUID: FolderUpload] = [:]

    /// Changes in the air, by the terminal they were asked through.
    ///
    /// One per terminal, and deliberately: the Mac answers a change by naming the path it was
    /// given, so two operations through one shell would be two answers matched against one
    /// remembered request. The entry is also what disables the controls, so the second tap that
    /// would cause that cannot be made.
    var changes: [UUID: FileChange] = [:]

    /// Why a change did not happen, by the terminal it was asked through.
    ///
    /// Deliberately not in ``uploadFailures`` or ``browseFailures``, and the reason is what the
    /// panel does with each of them: a browse failure replaces the list with a full-panel state,
    /// which is right for a folder that could not be read and wrong for a rename that could not
    /// land — the user would lose the folder they are looking at, along with the row they were
    /// about to try again on. This one is drawn above the list, which stays where it is.
    var changeFailures: [UUID: String] = [:]

    // MARK: - The picture's on/off switch

    /// Asks this Mac for the picture, or for silence, and touches nothing else.
    ///
    /// The session, its control channel, its shells, its clipboard and the assertion that keeps
    /// the Mac awake all survive this, which is the whole point of the command existing: a Mac
    /// nobody is looking at should not be spending its battery or the operator's bandwidth, but
    /// it should still be a Mac somebody is connected to.
    ///
    /// **Silent for a Mac that cannot take it.** See ``PicturePause/mayAsk(hostDeclared:)``: an
    /// un-updated Mac goes on streaming, which costs bandwidth and nothing else, where sending
    /// anyway would cost the session.
    func setPicturePaused(_ paused: Bool) {
        guard PicturePause.mayAsk(hostDeclared: hostSupportsVideoPause) else { return }
        guard phase.holdsSession, paused != picturePaused else { return }
        picturePaused = paused
        send(.setVideoEnabled(!paused))

        if paused {
            // A measurement belongs to a request that is still outstanding, and this one has just
            // been superseded by the picture stopping.
            pictureResumedAt = nil
            pictureResumeBaselineFrames = nil
        } else {
            // Taken before the frame arrives, which is the only moment it can be taken: the
            // renderer's total at the instant the ask went out is what "the first frame back"
            // is measured from.
            pictureResumedAt = Date()
            pictureResumeBaselineFrames = renderer.currentSnapshot.framesEnqueued
            lastResumeMilliseconds = nil
        }
    }

    /// Times the picture's return, once there is a frame to time it by.
    ///
    /// Called from the poll rather than from the event path, because the question is "has
    /// anything arrived", and the frame that answers it is deliberately not allowed to touch the
    /// main actor on its way past. See the event handler in ``SessionModel/connect(to:)``.
    ///
    /// **A count that has moved in either direction counts as an answer.** Forwards is a frame
    /// that arrived; backwards is the renderer's own total resetting, which happens when the Mac
    /// re-sends its stream description on the way back, and that is the picture starting again
    /// just as much as a frame is.
    func measureResumeIfNeeded(_ snapshot: VideoRenderer.Snapshot) {
        guard let resumedAt = pictureResumedAt, let baseline = pictureResumeBaselineFrames else { return }
        guard snapshot.framesEnqueued != baseline else { return }

        pictureResumedAt = nil
        pictureResumeBaselineFrames = nil
        let milliseconds = Date().timeIntervalSince(resumedAt) * 1000
        lastResumeMilliseconds = milliseconds
        append(note: "Picture back \(Int(milliseconds.rounded())) ms after asking for it")
    }

    // MARK: - Sending

    /// The only path a command takes to this Mac.
    ///
    /// Everything goes through the session's coalescer, so the rules about what may be merged and
    /// what must never be dropped live in one place instead of in each gesture recogniser.
    func send(_ command: RemoteCommand) {
        wire?.send(command)
    }

    // MARK: - Quality

    /// Whether the app is choosing the rate, or the person watching is.
    var isAutomaticQuality: Bool { model.streamQuality == .auto }

    /// Which path the rate policy is tuned for.
    var autoQualityPath: AutoQualityPolicy.Path {
        switch connectionPath {
        case .lan: return .lan
        case .relay: return .relay
        case .direct, nil: return .direct
        }
    }

    /// The fastest the picture may go on this session, which is the plan's answer and the path's.
    ///
    /// **Uncapped on the direct path, for every plan.** Two devices on one network are not spending
    /// anybody's bandwidth but their own, so there is nothing there to sell and capping it would
    /// make the one demonstration most people see first worse for no reason. A relayed session is
    /// the operator's link, and 20 Mbps down it is five times the bandwidth of 8, which is what
    /// ``PlanCapability/highBitrate`` is about.
    ///
    /// Per Mac, and rightly: one Mac can be on the LAN while another is on the relay, so the two
    /// ceilings are genuinely different numbers at the same moment.
    var videoCeiling: AutoQualityPolicy.Tier {
        guard autoQualityPath == .relay else { return .high }
        return model.storeManager.access.includes(.highBitrate) ? .high : .medium
    }

    /// Switches between the app choosing the rate and the person watching choosing it.
    ///
    /// Turning manual on does not mean "high": it means "let me choose", and the level it lands
    /// on is the one picked last — or, the first time, the rate the policy had already settled
    /// on. Landing anywhere else would be a jump in the picture at the exact moment someone
    /// asked for control of it.
    func setAutomaticQuality(_ automatic: Bool) {
        setStreamQuality(automatic ? .auto : (model.lastManualQuality ?? StreamQuality(autoQualityPolicy.tier)))
    }

    /// Sets the preset, tells this Mac, and remembers it.
    ///
    /// The save is what makes the Settings tab's row and this one the same setting rather than
    /// two: whichever is used, the stored token ends up saying the same thing, so the next
    /// session starts where this one was left.
    func setStreamQuality(_ quality: StreamQuality) {
        // **The one rung a plan can be short of, and only while the bytes are being carried.**
        // Asking for it opens the plans rather than being quietly capped, because a picture that
        // silently stayed soft is a setting that reads as broken. High on a session going straight
        // between the two devices is not gated at all: see ``videoCeiling``.
        if quality == .high, videoCeiling == .medium {
            model.paywallReason = .feature(.highBitrate)
            return
        }
        model.rememberQualityChoice(quality)
        if let bitrateKbps = quality.bitrateKbps {
            send(.setStreamQuality(fps: 0, bitrateKbps: min(bitrateKbps, videoCeiling.bitrateKbps)))
        } else {
            autoQualityPolicy = AutoQualityPolicy(path: autoQualityPath, ceiling: videoCeiling)
            lastAutoDroppedFrames = renderer.currentSnapshot.framesDropped
            send(.setStreamQuality(fps: 0, bitrateKbps: autoQualityPolicy.tier.bitrateKbps))
        }
    }

    /// Hands this Mac the quality the app is set to, when the session arrives.
    ///
    /// **Every arrival, and not only an automatic one.** It used to return early unless the
    /// preset was ``StreamQuality/auto``, which left a manual level unsent after a reconnect —
    /// and the Mac does not keep the figure across one: it clears `requestedBitrateKbps` when
    /// the video peer closes and falls back to its own preferred rate, which is the top one. So
    /// a phone reading "Low" could be watching a 20 Mbps stream, and the speed chip would have
    /// been describing a setting that had stopped taking. Sending on each arrival costs one
    /// message and makes the chip honest.
    ///
    /// **The stored token is read rather than ``SessionModel/streamQuality`` being trusted.**
    /// That property is seeded once, when the model is built — and the model is built once, for
    /// the life of the process. The Settings tab writes the preference and cannot reach this
    /// object at all, because that tab is unreachable while a session runs, which is the whole
    /// reason it writes a preference instead of sending a command. So between a change made
    /// there and the connect that follows, the two disagree, and the property is the stale one.
    func applyInitialQuality() {
        let quality = SessionModel.storedQuality
        model.streamQuality = quality

        autoQualityPolicy = AutoQualityPolicy(path: autoQualityPath, ceiling: videoCeiling)
        lastAutoDroppedFrames = 0

        if let bitrateKbps = quality.bitrateKbps {
            model.lastManualQuality = quality
            send(.setStreamQuality(fps: 0, bitrateKbps: min(bitrateKbps, videoCeiling.bitrateKbps)))
        } else {
            send(.setStreamQuality(fps: 0, bitrateKbps: autoQualityPolicy.tier.bitrateKbps))
        }
    }

    func updateAutoQuality(from snapshot: VideoRenderer.Snapshot) {
        guard model.streamQuality == .auto, let latencyMilliseconds else {
            lastAutoDroppedFrames = snapshot.framesDropped
            return
        }

        // On the control channel the host is holding the rate down on purpose, and the client
        // asking for more would be asking it to break its own ceiling — see
        // ``VideoCoordinator/effectiveBitrateKbps``. This end stops driving the number and
        // lets the cap stand until the picture moves back. The measurement is still taken, so
        // the policy starts from a clean window rather than from a stale one.
        guard videoTransport == .primary else {
            lastAutoDroppedFrames = snapshot.framesDropped
            return
        }

        let newDrops = snapshot.framesDropped >= lastAutoDroppedFrames
            ? snapshot.framesDropped - lastAutoDroppedFrames
            : 0
        lastAutoDroppedFrames = snapshot.framesDropped

        guard let tier = autoQualityPolicy.observe(
            latencyMilliseconds: latencyMilliseconds,
            newDroppedFrames: newDrops
        ) else { return }
        send(.setStreamQuality(fps: 0, bitrateKbps: tier.bitrateKbps))
        append(note: "Auto quality changed to \(tier.bitrateKbps / 1_000) Mbps")
    }

    // MARK: - The captured picture

    var activeSourceTitle: String? {
        // **A mosaic is named before the catalogue is asked**, because the catalogue has no row
        // for it and never will: it is not something the Mac offers, it is something the app
        // asked for. Without this the pill would say nothing at all while a canvas was up,
        // which reads as a session that has lost track of what it is showing.
        if let layout = mosaicLayout, isShowingMosaic {
            return "\(layout.tiles.count) windows"
        }
        guard let activeSourceID,
              let descriptor = catalog?.all.first(where: { $0.id == activeSourceID })
        else { return nil }
        return descriptor.title
    }

    /// Whether there is an arrangement to go back to, and the picture is not already it.
    ///
    /// The one condition the back control is drawn on, so it cannot be drawn in a session that
    /// has no mosaic (a button that took the user nowhere) or while the mosaic is on screen
    /// (a button that would do nothing at all).
    var canReturnToMosaic: Bool { mosaicLayout != nil && !isShowingMosaic }

    /// The size of the captured content in pixels, if it is known.
    ///
    /// The catalog is preferred over the video config: the catalog describes the source
    /// before any picture arrives, so the canvas can be laid out correctly while the Mac is
    /// still switching capture sources.
    var capturePixelSize: CGSize? {
        if let activeSourceID,
           let descriptor = catalog?.all.first(where: { $0.id == activeSourceID }),
           descriptor.pixelSize.width > 0, descriptor.pixelSize.height > 0 {
            return descriptor.pixelSize
        }
        let snapshot = renderer.currentSnapshot
        if snapshot.hasConfig, snapshot.pixelWidth > 0, snapshot.pixelHeight > 0 {
            return CGSize(width: snapshot.pixelWidth, height: snapshot.pixelHeight)
        }
        if let first = catalog?.displays.first { return first.pixelSize }
        return nil
    }

    /// The captured content's size in the Mac's *points*, which is the space
    /// ``RemoteCommand/joystickMove(dx:dy:)`` and ``RemoteCommand/scroll(dx:dy:)`` are in.
    ///
    /// Derived by halving the pixel size, i.e. assuming a 2× backing store. That is the only
    /// figure available: the protocol carries pixels, and the point-to-pixel scale of the
    /// captured surface is not part of it. It is an estimate, and it is used only to scale a
    /// relative nudge — being wrong by a factor of two changes how fast the cursor travels,
    /// not where it lands.
    var capturePointSize: CGSize {
        guard let pixels = capturePixelSize else { return CGSize(width: 1512, height: 982) }
        return CGSize(width: pixels.width / 2, height: pixels.height / 2)
    }

    /// The picture a video config describes, named as far as this end can name it.
    ///
    /// The catalogue is the only thing in the session that says what a source *is*, so it is
    /// also the only place the answer to "can this one change size on its own" comes from. A
    /// source with no catalogue entry behind it is left as unknown rather than guessed at, which
    /// ``PictureIdentity/contentMovesOnItsOwn`` reads as "free to move". See
    /// ``PictureIdentity/change(to:)`` for what that buys.
    func pictureIdentity(of config: VideoStreamConfig) -> PictureIdentity {
        // The rule is ``MacCastKit/PictureIdentity/forStream(_:activeSourceID:catalog:)``; this
        // reads the two things it needs off the session, which is the only part of it a test
        // cannot supply for itself.
        PictureIdentity.forStream(
            config,
            activeSourceID: activeSourceID,
            catalog: catalog,
            // **The arrangement as well as its name**, because a mosaic has no catalogue row and
            // the name alone cannot say what it is. See ``PictureIdentity/forStream(_:activeSourceID:catalog:source:)``.
            source: mosaicLayout.map { CaptureSource.mosaic($0) }
        )
    }

    // MARK: - Notes

    func append(note: String) {
        notes.append(note)
        if notes.count > 12 { notes.removeFirst(notes.count - 12) }
        if activeSessionHistoryID != nil {
            activeSessionLogs.append(note)
            if activeSessionLogs.count > 40 {
                activeSessionLogs.removeFirst(activeSessionLogs.count - 40)
            }
        }
    }
}
