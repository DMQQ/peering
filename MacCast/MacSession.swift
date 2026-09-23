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
/// Holds everything about a single Mac (phase, wire, picture, shells, folders, the record of the time
/// spent on it) so a second Mac can exist without the two sharing state. ``model`` is `unowned`: the
/// ownership runs the other way and is total, and the model outlives every session it makes.
@Observable
@MainActor
final class MacSession: Identifiable {
    /// Which way the control connection is being carried.
    ///
    /// Declared in ``MacCastKit`` and merely named here. Per Mac, because one can be on this network
    /// while the other is across the country, and the picture ceiling differs. See ``videoCeiling``.
    typealias ConnectionPath = MacCastKit.ConnectionPath

    /// The same three cases in the card's spelling, mapped because the raw values differ on purpose:
    /// this one is shouted at a diagnostics panel, the card's is set in a chip beside a sentence.
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
    /// reconnect), and the tab strip has to tell one of those apart from the other. Not a host ID
    /// either, which is not known until the handshake arrives.
    let id = UUID()

    /// The app-wide half of the session, which this is a part of.
    unowned let model: SessionModel

    /// The one decoder every session draws through.
    ///
    /// Shared on purpose: a renderer is the expensive thing a connection feeds, and one per session
    /// would run two hardware decoders for one pair of eyes.
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
    /// Stored app-wide, but the bitrate that reaches the wire depends on this session's path and
    /// this session's plan, so it is resolved per Mac.
    var connectionPath: ConnectionPath?
    var usedDirectPath = false
    var directPathStatus: ClientSession.DirectPath = .notTried

    /// What the relay's datagram lane carried, kept after the session ends.
    ///
    /// Kept rather than cleared because Settings cannot be opened while a session runs, so the only
    /// moment it can be read is just after one. `nil` when there was no datagram lane.
    var datagramCounts: ClientSession.DatagramCounts?

    /// Round trip of the control channel, which goes through the relay in every session.
    var latencyMilliseconds: Double?

    /// Round trip of the lane the picture is arriving on, and whether that lane is the direct one.
    ///
    /// ``latencyMilliseconds`` is the relay's even then, because the control connection carries input
    /// and always goes the long way. `nil` until a datagram lane exists.
    var pathLatencyMilliseconds: Double?
    var pathLatencyIsDirect = false

    /// When the session that is up now came up, for the elapsed-time readout.
    ///
    /// A `Date` and not a counter, so the view can use `Text(_:style:.timer)`, which the system
    /// advances itself; a `Timer` here would wake the main actor once a second to count.
    var sessionStartedAt: Date?

    /// Whether this connection ever reached a Mac.
    ///
    /// The phase cannot answer it: a dropped session and one that never got past the handshake are
    /// both `.failed`, and only the first should be retried. See ``resumeIfNeeded()``.
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
    /// Apart from `videoStatus`, which describes the stream: this describes a healthy stream whose
    /// every frame is black because the screen is asleep, and from the phone the two look identical.
    var remoteNotice: NoticePayload?
    var videoStatus = "No video stream"

    /// The frames per second arriving, as measured by the last two polls. Zero until there have been
    /// two samples to compare. See ``updateFrameRate(from:)``.
    var videoFramesPerSecond: Double = 0

    /// The frame count and the moment it was read, for the difference above.
    var lastFrameSample: (count: Int, at: Date)?

    /// True while the video channel is delivering frames (not ended/absent).
    var isVideoStreaming = false

    /// Which channel the picture is arriving on. `.control` means the Mac's network is not letting
    /// video through and the session has fallen back. See ``VideoFallbackPolicy``.
    var videoTransport: VideoTransport = .primary

    var videoPoll: Task<Void, Never>?
    /// The task inside the current attempt, retained so a user ending or replacing the session also
    /// cancels an in-flight relay WebSocket rather than only the TCP socket it may create.
    var connectTask: Task<Void, Never>?

    /// Whether the user asked for this session to end, read and cleared by the transition that
    /// follows.
    ///
    /// Per Mac: `disconnect()` ends every Mac at once and each answers with its own transition, so
    /// with one shared flag the first consumed it and every Mac after that read as having dropped.
    var userEndedDeliberately = false

    /// Takes this Mac's connection apart, and leaves the object for its last figures to be read.
    ///
    /// Not a disconnect of its own: the caller decides once whether the end was the user's or iOS's,
    /// and that answer is what is kept here. The record is filed first, because everything it
    /// describes is cleared below, and the player is released because its `deinit` stops the engine.
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
    /// Not `phase.holdsSession` on its own: a Mac that dropped and is being retried is one the user
    /// still has open. `hasBeenReady` is what stops a dial that failed before its handshake, which
    /// arms the same ladder, from counting as an open Mac and spending the free plan's allowance.
    var isLive: Bool { phase.holdsSession || (hasBeenReady && isReconnecting) }

    /// Whether this Mac dropped and is being put back, rather than being opened for the first time
    /// or dialled again by hand.
    ///
    /// Neither the phase nor ``isLive`` can tell a drop from a first connection, nor one that has
    /// just landed from a ladder that has run out; `hasGivenUpResuming` is that distinction. The rule
    /// lives in ``SessionResume``, where it can be tested.
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
    /// Per Mac: with a shared counter the second Mac's failure resets the first one's backoff, so a
    /// Mac that is switched off is dialled every second forever.
    var reconnectAttempt = 0
    var reconnectTask: Task<Void, Never>?

    /// Puts this Mac back, if it dropped and the user did not end it.
    ///
    /// The host is known, so this dials a named Mac, and each Mac runs its own ladder without
    /// resetting another's backoff. The `wire == nil` guard stops the retry and the browser both
    /// starting an attempt, since the wire is assigned synchronously in ``SessionModel/connect(to:)``.
    func resumeIfNeeded() {
        guard wire == nil, !phase.holdsSession else {
            if phase.holdsSession { stopReconnecting() }
            return
        }
        // Only a Mac that was actually connected: an attempt that failed at the handshake has ended
        // rather than waiting to come back, and retrying it forever is what the failure card is for.
        guard hasBeenReady || isReconnecting else { return }
        guard UserDefaults.standard.bool(forKey: SessionModel.resumeKey) else {
            // Nothing is going to put this Mac back, so it stops claiming one will. Without this,
            // `isReconnecting` stays set with no task behind it, so the Mac holds a session slot and
            // a tab for the rest of the launch with nothing that will ever clear the flag.
            stopReconnecting()
            return
        }
        guard let hostID else {
            // No handshake means no Mac to dial, which is the case for a first pairing whose ID was
            // mistyped, and there is nothing to retry.
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
            // The LAN-only case: the Mac is paired and simply not here yet. The ladder keeps asking
            // until it appears; stopping at the first attempt that found nothing would end a resume
            // that has not failed, only not succeeded yet.
            scheduleReconnect()
        }
    }

    /// Arms the next attempt, if there is one left to make.
    ///
    /// A resume gets the shorter ladder, chosen here rather than kept in the session because it has
    /// to match the counter: `reconnectAttempt` indexes into whichever ladder is being used.
    func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delays = isResumingAfterDrop
            ? SessionModel.resumeReconnectDelays
            : SessionModel.reconnectDelays
        guard reconnectAttempt < delays.count else {
            isReconnecting = false
            // Running out is the moment the app stops behaving like a session that is coming back:
            // this flag turns the remote screen over to the picker. The banner is not re-posted,
            // because `SessionAwareness` refuses a repeat of the phase it is already in.
            hasGivenUpResuming = true
            // The screen is about to leave and no replacement stream will reuse its display, so this
            // is the terminal path that releases the attachment non-deliberate teardown kept alive
            // for the retry. A background Mac shares the active Mac's renderer and must not detach
            // it.
            if isActive { renderer.detach() }
            // No phase change happened, so `sessionMoved` is not called again and the Live Activity
            // has to be told directly or it stays on "Reconnecting…". Only for the Mac on screen: a
            // background Mac giving up is a banner, not a card.
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

        // The phone's network may already have moved and gone unacted on, because at that moment
        // nothing was being put back, and a relay socket can hang for the whole of the silence
        // watchdog. Asked here because this is the only place a wait begins, and deferred by a turn
        // because the answer can dial: the rest of the phase change has to finish first. Only for a
        // Mac being put back, since a first connection's ladder is a wait with nothing to hurry.
        if isResumingAfterDrop {
            Task { @MainActor [model] in model.considerNetworkChange() }
        }
    }

    /// Stops the retry, without resetting the backoff. See
    /// ``SessionModel/stopReconnecting()`` for why the counter is not cleared here.
    func stopReconnecting() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
    }

    // MARK: - Asking this Mac for the picture, and for silence

    /// What this Mac said about being asked to pause. See ``PicturePause/mayAsk(hostDeclared:)``.
    ///
    /// Never assumed: `false` is a Mac too old to have been asked, where the command means a dropped
    /// session rather than a picture that stops.
    var hostSupportsVideoPause = false

    /// What this Mac said about carrying a picture on the clipboard. See
    /// ``ClipboardImages/maySend(toHostDeclared:)``.
    ///
    /// Never assumed: the command is one a Mac this old cannot decode at all, so sending it is a
    /// mid-session failure rather than a copy that quietly does nothing.
    var hostSupportsClipboardImages = false

    /// What the user put together: these windows, in this order, with these sizes.
    ///
    /// The intent rather than the rectangles, which are stale the moment the phone rotates (see
    /// ``MosaicGrid``). Held per Mac: an arrangement is a place on this Mac, so a session that comes
    /// back to a different one must not offer a mosaic of windows that are not there.
    var mosaicChoices: [MosaicChoice] = []

    /// The re-ask a rotation has scheduled, if the phone is still settling from one.
    ///
    /// On the session because the model outlives it: a rotation pending when a connection ended
    /// would otherwise be delivered to the next Mac, as a mosaic of windows that are not there.
    var mosaicViewportTask: Task<Void, Never>?

    /// The "has anything gone" check a catalogue change schedules.
    ///
    /// On the session for the same reason the rotation's is: it is a question about this Mac's
    /// windows and must not be run against the next one.
    var mosaicGapTask: Task<Void, Never>?

    /// Sources whose asking has already produced nothing, by ``CaptureSource/stableID``.
    ///
    /// A tile the Mac cannot capture looks exactly like one it can: its card is drawn into the canvas
    /// by the Mac and ScreenCaptureKit goes on listing a window it will not render, so the tap is the
    /// only way to learn it. Emptied by ``SessionModel/showMosaic(_:)``, the user asking afresh.
    var sourcesThatOpenedNothing: Set<String> = []

    /// The pending wait for a tapped tile to open. See ``RemoteScreen/watchTileOpening(_:)``.
    var tileOpeningWatch: Task<Void, Never>?

    /// Whether the picture the user asked for is an arrangement rather than one of its tiles.
    ///
    /// It has to survive a rotation: ``mosaicLayout`` is built from the live screen size, so its
    /// identifier stops matching ``activeSourceID`` once the phone turns. Set by ``selectSource(_:)``
    /// from the source itself, so it cannot drift.
    var isAskingForMosaic = false

    /// The arrangement as the Mac is being asked for it, built from those choices.
    var mosaicLayout: MosaicLayout? {
        MosaicGrid.layout(
            choices: mosaicChoices,
            viewport: mosaicViewport,
            tileAspect: mosaicTileAspect
        )
    }

    /// How wide the things in the arrangement are, which is what its tiles are shaped by.
    ///
    /// The median of what the catalogue knows, and a window if it knows nothing: the median ignores
    /// the one odd window rather than being dragged by it, and sources the catalogue cannot describe
    /// are left out of the count rather than guessed at.
    var mosaicTileAspect: Double {
        let aspects = mosaicChoices
            .compactMap { catalog?.descriptor(for: $0.source)?.pixelSize }
            .filter { $0.width > 0 && $0.height > 0 }
            .map { Double($0.width / $0.height) }
            .sorted()
        guard !aspects.isEmpty else { return MosaicGrid.windowAspect }
        // Clamped, because one pathological source should not ask a Mac for a canvas of a shape
        // nothing in the picture is: a 40-pixel strip of a window is a real thing to capture and
        // a bad thing to build a grid out of.
        return min(max(aspects[aspects.count / 2], 0.5), 3.0)
    }

    /// The canvas a mosaic is asked for: the phone's own screen in pixels, the way up it is being
    /// held.
    ///
    /// The shape comes from the interface and the pixels from the screen: `bounds` does not change
    /// when the phone turns, only which number is the width, and iOS takes about two seconds to say
    /// so, while the interface knows from the first frame. Read from the window scene, not
    /// `UIScreen.main`.
    var mosaicViewport: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        else {
            // No scene at all, which is a state the app cannot act in rather than a case to handle:
            // a canvas a Mac will accept, so nothing downstream has to.
            return CGSize(width: 1280, height: 720)
        }
        let bounds = scene.screen.bounds
        let scale = scene.screen.scale
        let longer = max(bounds.width, bounds.height) * scale
        let shorter = min(bounds.width, bounds.height) * scale
        return scene.effectiveGeometry.interfaceOrientation.isLandscape
            ? CGSize(width: longer, height: shorter)
            : CGSize(width: shorter, height: longer)
    }

    /// The arrangement the picture on screen is of, or `nil` when the picture is a single source.
    ///
    /// Recorded when the Mac answers, not when the app asks: the Mac takes a second or two to build
    /// the new tiles, and until it does the picture is the old canvas. Everything drawn over the
    /// picture has to agree with the picture. See ``MacSession/apply(video:)``.
    var pictureMosaicLayout: MosaicLayout?

    /// The arrangement this end last asked the Mac for, frozen at the moment it asked.
    ///
    /// Frozen, because ``mosaicLayout`` is not: it is rebuilt from the live screen and catalogue on
    /// every read, so reading it when the Mac answers records an arrangement the Mac may never have
    /// built. Set by ``SessionModel/selectSource(_:)``, the one door every ask goes through.
    var askedMosaicLayout: MosaicLayout?

    /// Whether the picture on screen is that arrangement rather than one of its tiles.
    ///
    /// Read off the arrangement that has arrived rather than off the one being asked for. See
    /// ``pictureMosaicLayout``.
    var isShowingMosaic: Bool { pictureMosaicLayout != nil }

    /// What this Mac said about building a mosaic. See ``MosaicSupport/maySend(hostDeclared:)``.
    ///
    /// Never assumed, which matters more here than anywhere else on this list: an un-updated Mac
    /// cannot decode a capture source, and the request goes out when the user asks for a whole
    /// arrangement. Sending it anyway ends the session.
    var hostSupportsMosaic = false

    /// What this Mac said about photographing its running applications. See
    /// ``SourceThumbnailSupport/maySend(hostDeclared:)``.
    ///
    /// Gated at an easier moment to reach than the mosaic: the request goes out when the Apps panel
    /// opens, so sending it to a Mac that cannot decode it ends the session.
    var hostSupportsSourceThumbnails = false

    /// Whether the picture is stopped because this client asked for it to be.
    ///
    /// Not the same as the picture being stopped: a sleeping screen, a failed stream and a pause this
    /// end requested all look alike, and only the third is something this end may undo.
    var picturePaused = false

    /// When the picture was last asked for again, and how long it took to come back.
    ///
    /// The request goes out here and the frames come back to the renderer, so this is the only place
    /// both ends of the interval are visible. Reported into the notes and Diagnostics, not shown.
    var pictureResumedAt: Date?
    var pictureResumeBaselineFrames: Int?
    var lastResumeMilliseconds: Double?

    var autoQualityPolicy = AutoQualityPolicy(path: .lan)
    var lastAutoDroppedFrames = 0

    /// A note about this Mac, newest last.
    ///
    /// Per Mac, because the notes are what the session's own log is made of, and one Mac's diagnosis
    /// must not carry sentences about another.
    var notes: [String] = []

    // MARK: - Session history

    /// How many notes a record's log keeps.
    ///
    /// One number for a session that is up and for the record it becomes, because the record is
    /// written to `UserDefaults` and read back at launch, so this is a size as much as a limit.
    static let sessionLogLimit = 40

    var activeSessionHistoryID: UUID?
    var activeSessionHistoryStartedAt: Date?
    var activeSessionBytes: Int64 = 0
    var lastBandwidthSampleBytes: Int64 = 0
    var activeSessionLogs: [String] = []

    /// The record a dropped session left in the history that this session is going on being, if
    /// this session is a reconnect rather than a connection.
    ///
    /// Held as the record's identity and totals rather than its index, because the list moves under
    /// anything positional while a session is up. See ``SessionContinuation``.
    var activeSessionContinuation: SessionContinuation?

    /// Whether this is the Mac the user is looking at.
    var isActive: Bool { model.activeSessionID == id }

    /// Whether this Mac's sound should be coming out of the phone.
    ///
    /// The switch and the plan decide whether host audio plays at all; being the Mac on screen decides
    /// whose, and without that second condition two Macs open at once are two audio engines decoding
    /// into one pair of ears. The price is that a Mac behind the one on screen is silent.
    var shouldPlayAudio: Bool { isActive && model.playsHostAudio }

    /// Applies the answer above to the player this Mac has, if it has one.
    ///
    /// Called when a config arrives and again when the active Mac changes: a Mac can be switched to
    /// long after its player was built, and a player built for the Mac on screen goes on playing
    /// after the user has looked away unless it is told.
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

    /// The command last sent, and when, so the shell's answer can be read against it.
    ///
    /// A PTY gives a byte stream with no marker for where one command's output starts, so the only
    /// thing that ties a message to a command is that it arrived right after one.
    var lastSentCommand: String?
    var lastSentAt: Date?

    // MARK: - File browsing

    /// Every folder the Mac has listed, keyed by the terminal it was listed for and the path it
    /// was listed at. See ``RemoteDirectoryKey``.
    ///
    /// Held rather than asked for per appearance, so stepping into a folder and back out is instant.
    var directories: [RemoteDirectoryKey: RemoteDirectory] = [:]

    /// Which folder each terminal's browser is showing, and no entry for a browser that has not
    /// opened yet or one still waiting on the Mac's home folder to resolve to a path.
    var browsingPaths: [UUID: String] = [:]

    /// Folders asked for and not yet answered, which is what a spinner on the panel is reading.
    var pendingDirectories: Set<RemoteDirectoryKey> = []

    /// Why a folder could not be listed, until it lists.
    var browseFailures: [RemoteDirectoryKey: String] = [:]

    /// The file being shown, and how much of it has arrived. One at a time because only one can be
    /// on screen: opening another replaces it.
    var filePreview: RemoteFilePreview?

    /// A command waiting for the shell that will run it.
    ///
    /// A terminal has no id until the Mac answers that it made one, so the command cannot be sent on
    /// tap, only remembered until ``apply(terminal:)`` sees the shell arrive. One at a time: a second
    /// tap in that window means to run the second file, not both.
    var pendingRun: String?

    /// A file on its way to the Mac, and which door it came through.
    struct FileWrite: Equatable {
        /// Whether the file is an editor's text or one the user picked.
        ///
        /// The two are answered differently and are the same operation: a save reads the file back so
        /// the editor shows what is on disk, an upload asks for the folder again so the new file
        /// appears. The rest is shared, which is why they share a record.
        enum Door { case save, upload }

        let door: Door
        /// The file being written. What the Mac's answer is matched on, since it names the file it
        /// wrote, and what says which folder to ask for again after an upload.
        let path: String
    }

    /// Files on their way to the Mac, by the terminal they are being written through.
    ///
    /// By terminal rather than one flag, because two can be in the air at once and a single flag
    /// hands the first answer to arrive to whichever transfer asked second.
    var writes: [UUID: FileWrite] = [:]

    /// Why a write did not land, by the terminal it was made through, and kept apart by door.
    ///
    /// Apart, because a save that failed is a file to correct and an upload that failed is a file to
    /// choose again. Read through ``saveFailure(sessionID:)`` and ``uploadFailure(sessionID:)`` so
    /// the panel asks about the terminal it is drawing.
    var saveFailures: [UUID: String] = [:]
    var uploadFailures: [UUID: String] = [:]

    /// Something being made, renamed or removed on the Mac, and which folder to ask about after.
    struct FileChange: Equatable {
        /// What is being asked for. Held rather than only the path, because the answer says what
        /// happened but not what was asked, and the path a rename moves is built from both.
        let operation: RemoteFileOperation
        /// The path the request named: the file's own path for a rename, not the one it becomes.
        /// What the Mac's answer is matched on, since it echoes back what it was sent.
        let path: String
    }

    /// Folders being sent to the Mac, by the terminal they are being sent through.
    ///
    /// A folder is a sequence of the operations beside it, not a kind of its own: the Mac already
    /// answers "make a folder" and "write this file", so nothing about the protocol knows a folder is
    /// involved. One per shell, because the Mac answers an operation by naming the path it was given.
    var folderUploads: [UUID: FolderUpload] = [:]

    /// Changes in the air, by the terminal they were asked through.
    ///
    /// One per terminal: the Mac answers a change by naming the path it was given, so two operations
    /// through one shell would both match one remembered request. The entry is also what disables the
    /// controls, so the second tap cannot be made.
    var changes: [UUID: FileChange] = [:]

    /// Why a change did not happen, by the terminal it was asked through.
    ///
    /// Not in ``uploadFailures`` or ``browseFailures``, because of what the panel does with each: a
    /// browse failure replaces the list with a full-panel state, which a rename that could not land
    /// must not do. This one is drawn above the list, which stays where it is.
    var changeFailures: [UUID: String] = [:]

    // MARK: - The picture's on/off switch

    /// Asks this Mac for the picture, or for silence, and touches nothing else.
    ///
    /// The session, its control channel, its shells, its clipboard and the assertion that keeps the
    /// Mac awake all survive this: a Mac nobody is looking at should not be spending battery or
    /// bandwidth, but it is still a Mac somebody is connected to. Silent for a Mac that cannot take it.
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
    /// Called from the poll rather than the event path, because the frame that answers "has anything
    /// arrived" may not touch the main actor on its way past. A count that has moved in either
    /// direction counts: forwards is a frame, backwards the renderer's total resetting.
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
    /// Uncapped on the direct path, for every plan: two devices on one network spend nobody's
    /// bandwidth but their own, so there is nothing to sell. A relayed session is the operator's
    /// link, and ``PlanCapability/highBitrate`` is what buys 20 Mbps there instead of 8.
    var videoCeiling: AutoQualityPolicy.Tier {
        guard autoQualityPath == .relay else { return .high }
        return model.storeManager.access.includes(.highBitrate) ? .high : .medium
    }

    /// Switches between the app choosing the rate and the person watching choosing it.
    ///
    /// Turning manual on does not mean "high": it lands on the level picked last, or the rate the
    /// policy had already settled on, so the picture does not jump at the moment control is asked for.
    func setAutomaticQuality(_ automatic: Bool) {
        setStreamQuality(automatic ? .auto : (model.lastManualQuality ?? StreamQuality(autoQualityPolicy.tier)))
    }

    /// Sets the preset, tells this Mac, and remembers it.
    ///
    /// The save is what makes the Settings tab's row and this one the same setting rather than two:
    /// whichever is used, the stored token ends up saying the same thing.
    func setStreamQuality(_ quality: StreamQuality) {
        // The one rung a plan can be short of, and only while the bytes are being carried. Asking
        // for it opens the plans rather than being quietly capped, because a picture that silently
        // stayed soft is a setting that reads as broken. High on a session going straight between
        // the two devices is not gated at all: see ``videoCeiling``.
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
    /// Every arrival, not only an automatic one: the Mac clears `requestedBitrateKbps` when the
    /// video peer closes and falls back to its own top rate, so an unsent manual level leaves a phone
    /// reading "Low" while watching 20 Mbps. The stored token is read rather than
    /// ``SessionModel/streamQuality``, which the Settings tab can leave stale.
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

        // On the control channel the host is holding the rate down on purpose, and the client asking
        // for more would be asking it to break its own ceiling: see
        // ``VideoCoordinator/effectiveBitrateKbps``. This end stops driving the number, and the
        // measurement is still taken so the policy starts from a clean window.
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
        // A mosaic is named before the catalogue is asked, because the catalogue has no row for it
        // and never will: it is not something the Mac offers, it is something the app asked for. And
        // it is named from the ask as well as the answer, so the pill names the arrangement as soon
        // as it is asked for rather than only once the Mac has built it.
        if isAskingForMosaic, let layout = mosaicLayout {
            return "\(layout.tiles.count) windows"
        }
        guard let activeSourceID,
              let descriptor = catalog?.all.first(where: { $0.id == activeSourceID })
        else { return nil }
        return descriptor.title
    }

    /// Whether there is an arrangement to go back to, and the picture is not already it.
    ///
    /// The one condition the back control is drawn on. Answered from what the picture is rather than
    /// what was asked for, so a mosaic the Mac refuses to build does not leave the arrangement
    /// unreachable, and the ask counts too, so it is not offered while the canvas is being built.
    var canReturnToMosaic: Bool {
        mosaicLayout != nil && !isShowingMosaic && !isAskingForMosaic
    }

    /// The size of the captured content in pixels, if it is known.
    ///
    /// The picture that is on screen, not the one being asked for: everything drawn over the picture
    /// is measured against this, and a rectangle measured against a picture that has not arrived is
    /// drawn on the wrong one.
    ///
    /// ``picture`` is asked first and the catalogue second, which answers only when there is no
    /// picture at all. See ``capturePointSize``, which is this halved.
    var capturePixelSize: CGSize? {
        if let picture, picture.pixelSize.width > 0, picture.pixelSize.height > 0 {
            return picture.pixelSize
        }
        if let activeSourceID,
           let descriptor = catalog?.all.first(where: { $0.id == activeSourceID }),
           descriptor.pixelSize.width > 0, descriptor.pixelSize.height > 0 {
            return descriptor.pixelSize
        }
        if let first = catalog?.displays.first { return first.pixelSize }
        return nil
    }

    /// The captured content's size in the Mac's points, which is the space
    /// ``RemoteCommand/joystickMove(dx:dy:)`` and ``RemoteCommand/scroll(dx:dy:)`` are in.
    ///
    /// Derived by halving the pixel size, i.e. assuming a 2x backing store: the protocol carries
    /// pixels and not the capture surface's point-to-pixel scale. It only scales a relative nudge, so
    /// a factor of two changes how fast the cursor travels, not where it lands.
    var capturePointSize: CGSize {
        guard let pixels = capturePixelSize else { return CGSize(width: 1512, height: 982) }
        return CGSize(width: pixels.width / 2, height: pixels.height / 2)
    }

    /// The picture a video config describes, named as far as this end can name it.
    ///
    /// The catalogue is the only thing in the session that says what a source is, so it is also the
    /// only place "can this one change size on its own" comes from. A source with no catalogue entry
    /// behind it is left as unknown rather than guessed at. See ``PictureIdentity/change(to:)``.
    func pictureIdentity(of config: VideoStreamConfig) -> PictureIdentity {
        // The rule is ``MacCastKit/PictureIdentity/forStream(_:activeSourceID:catalog:)``; this
        // reads the two things it needs off the session, which is the only part of it a test
        // cannot supply for itself.
        PictureIdentity.forStream(
            config,
            activeSourceID: activeSourceID,
            catalog: catalog,
            // The arrangement as well as its name, because a mosaic has no catalogue row and
            // the name alone cannot say what it is.
            source: mosaicLayout.map { CaptureSource.mosaic($0) }
        )
    }

    // MARK: - Notes

    func append(note: String) {
        notes.append(note)
        if notes.count > 12 { notes.removeFirst(notes.count - 12) }
        if activeSessionHistoryID != nil {
            activeSessionLogs.append(note)
            if activeSessionLogs.count > Self.sessionLogLimit {
                activeSessionLogs.removeFirst(activeSessionLogs.count - Self.sessionLogLimit)
            }
        }
    }
}
