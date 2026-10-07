import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import os

private let sessionLog = Logger(subsystem: "pl.dmq.peering", category: "session")

/// ``model`` is `unowned`: ownership runs the other way and is total.
@Observable
@MainActor
final class MacSession: Identifiable {
    /// Per Mac: one can be on this network while another is across the country, and the picture ceiling differs. See ``videoCeiling``.
    typealias ConnectionPath = MacCastKit.ConnectionPath

    /// Mapped because the raw values differ on purpose: this one is shouted at a diagnostics panel, the card's is set in a chip.
    static func activityPath(_ path: ConnectionPath?) -> SessionActivityAttributes.Path? {
        switch path {
        case .lan: return .lan
        case .relay: return .relay
        case .direct: return .direct
        case nil: return nil
        }
    }

    // MARK: - Identity

    /// Not the Mac's ID: a Mac can be connected twice in a launch (a drop, a reconnect) and the tab strip must tell them apart.
    let id = UUID()

    unowned let model: SessionModel

    /// Shared on purpose: a renderer is the expensive part, and one per session would run two hardware decoders.
    @ObservationIgnored let renderer: VideoRenderer

    init(model: SessionModel, renderer: VideoRenderer) {
        self.model = model
        self.renderer = renderer
    }

    // MARK: - Connection state

    var phase: ClientSession.Phase = .idle

    var wire: ClientSession?

    var hostID: String?

    var hostName: String?

    /// Resolved per Mac: the bitrate on the wire depends on this session's path and plan.
    var connectionPath: ConnectionPath?
    var usedDirectPath = false
    var directPathStatus: ClientSession.DirectPath = .notTried

    /// Kept after the session ends because Settings cannot be opened while one runs. `nil` when there was no datagram lane.
    var datagramCounts: ClientSession.DatagramCounts?

    var latencyMilliseconds: Double?

    /// ``latencyMilliseconds`` stays the relay's even then: the control connection carries input and always goes the long way.
    var pathLatencyMilliseconds: Double?
    var pathLatencyIsDirect = false

    /// A `Date`, so the view can use `Text(_:style:.timer)`; a `Timer` would wake the main actor each second.
    var sessionStartedAt: Date?

    /// The phase cannot answer it: a dropped session and one that never got past the handshake are both `.failed`, and only the first should be retried. See ``resumeIfNeeded()``.
    var hasBeenReady = false

    /// The host always restores brightness when the last client disconnects.
    var privacyModeEnabled = false

    // MARK: - The picture

    var catalog: CaptureCatalog?
    var activeSourceID: String?
    var picture: PictureIdentity?

    /// Apart from `videoStatus`: this describes a healthy stream whose every frame is black because the screen is asleep, which looks identical from the phone.
    var remoteNotice: NoticePayload?
    var unlockDetour: (lockScreen: CaptureSource, returnTo: CaptureSource)?
    var sourceRequestedOnOpen: String?
    var videoStatus = String(localized: "No video stream")

    var videoFramesPerSecond: Double = 0

    var lastFrameSample: (count: Int, at: Date)?

    var isVideoStreaming = false

    /// Sticky, unlike ``isVideoStreaming``, which is false both before the first config and while the user has paused: only the first has nothing on screen to interrupt, so only a sticky flag may allow a relay-to-LAN handover. See ``SessionModel/apply(_:)``'s `.updated`.
    var hasHadPicture = false

    /// `.control` means the Mac's network is not letting video through and the session has fallen back. See ``VideoFallbackPolicy``.
    var videoTransport: VideoTransport = .primary

    var videoPoll: Task<Void, Never>?
    /// Retained so ending or replacing the session also cancels an in-flight relay WebSocket, not only the TCP socket.
    var connectTask: Task<Void, Never>?
    var sourceToResume: CaptureSource? {
        if activeSourceID?.hasPrefix("mosaic:") == true {
            guard model.storeManager.access.includes(.mosaic) else { return nil }
            return askedMosaicLayout.map { .mosaic($0) }
        }
        return catalog?.all.first { $0.id == activeSourceID }?.source
    }

    var dialRace: DialRace?

    /// Set once and never cleared: the object is one attempt at one Mac, and everything that must know the user meant it (retry ladder, screens asking whether it is being put back) reads it long after the transition. Clearing it left a Quit showing "reconnecting" until tapped twice.
    /// Per Mac: `disconnect()` ends every Mac at once, and with one shared flag the first consumed it and the rest read as dropped.
    var userEndedDeliberately = false

    /// The record is filed first because everything it describes is cleared below, and the player is released because its `deinit` stops the engine.
    func endSession(deliberate: Bool) {
        userEndedDeliberately = deliberate
        finishSessionHistory()
        connectTask?.cancel()
        connectTask = nil
        // Cleared here rather than in `stopReconnecting()`, which every rung calls before dialling: this is the end of the episode, and that is not.
        reconnectingSince = nil
        stopReconnecting()
        dialRace?.cancel()
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

    /// Not `phase.holdsSession` alone: a dropped Mac being retried is still open. `hasBeenReady` stops a dial that failed before its handshake, which arms the same ladder, from counting as an open Mac and spending the free plan's allowance.
    var isLive: Bool { phase.holdsSession || (hasBeenReady && isReconnecting) }

    /// Neither the phase nor ``isLive`` can tell a drop from a first connection, or one just landed from a ladder that has run out; `hasGivenUpResuming` is that distinction. The rule lives in ``SessionResume``, where it can be tested.
    var isResumingAfterDrop: Bool {
        SessionResume.isUnderWay(
            hasBeenReady: hasBeenReady,
            userEndedDeliberately: userEndedDeliberately,
            hasGivenUpResuming: hasGivenUpResuming,
            isReconnecting: isReconnecting,
            phase: phase
        )
    }

    /// Set when the retry ladder runs out; cleared when a session is up again.
    var hasGivenUpResuming = false

    var gaveUpAt: Date?

    /// The one resume a session cannot recognise on its own: a cold launch has no object to carry `hasBeenReady` from (iOS killed the process), so the intent arrives with the dial and is put here by ``SessionModel/connect(to:replacing:)``.
    var isComingBack = false

    /// `.ready` is excluded by name because every other flag stays true through it. The user's word ends it: `isComingBack` is cleared only where a ladder runs out, so a Quit tapped mid-resume left the screen saying it was reconnecting with nothing to press to leave.
    var isBeingPutBack: Bool {
        guard phase != .ready, !userEndedDeliberately else { return false }
        return isResumingAfterDrop || isComingBack
    }

    var isReconnecting = false

    /// Per Mac: with a shared counter the second Mac's failure resets the first's backoff, so a Mac that is switched off is dialled every second forever.
    var reconnectAttempt = 0
    var reconnectTask: Task<Void, Never>?

    /// Carried across a dial like ``hasBeenReady`` and ``reconnectAttempt``, since each rung builds a new object. See ``SessionModel/reconnectWindow``.
    var reconnectingSince: Date?

    private var hasReconnectWindowPassed: Bool {
        guard let began = reconnectingSince else { return false }
        return Date().timeIntervalSince(began) >= SessionModel.reconnectWindow
    }

    /// The `wire == nil` guard stops the retry and the browser both starting an attempt, since the wire is assigned synchronously in ``SessionModel/connect(to:)``.
    func resumeIfNeeded() {
        CrashLog.note("resume check · \(hostID ?? "unknown") · phase \(phase) · attempt \(reconnectAttempt)")
        guard wire == nil, !phase.holdsSession else {
            if phase.holdsSession { stopReconnecting() }
            return
        }
        // Only a Mac that was actually connected: an attempt that failed at the handshake has ended, and the failure card is for that.
        guard hasBeenReady || isReconnecting else { return }
        guard UserDefaults.standard.bool(forKey: SessionModel.resumeKey) else {
            // Nothing will put this Mac back, so clear the claim: otherwise `isReconnecting` stays set with no task behind it and the Mac holds a session slot and tab for the rest of the launch.
            stopReconnecting()
            return
        }
        guard let hostID else {
            // No handshake means no Mac to dial (a mistyped first pairing ID), so nothing to retry.
            stopReconnecting()
            return
        }

        if let host = model.hosts.first(where: { $0.id == hostID }) {
            stopReconnecting()
            model.isResuming = true
            model.reconnect(self, to: .discovered(host))
        } else if let remembered = model.rememberedLANHost(hostID) {
            // Every rung tries the LAN, racing the relay: Bonjour not listing the Mac is the expected state of a resume (the Mac withdraws while a phone is connected), so the last good address is dialled first and the relay joins a moment later. See ``DialRace``.
            stopReconnecting()
            model.isResuming = true
            let relay = model.allowsRelay && model.pins.hostIDs.contains(hostID)
                ? model.relayTarget(hostID: hostID, name: hostName ?? String(localized: "A Mac"))
                : nil
            model.reconnect(
                self,
                to: .discovered(remembered),
                timeout: SessionModel.rememberedPathTimeout,
                racingRelay: relay
            )
        } else if model.allowsRelay, model.pins.hostIDs.contains(hostID) {
            stopReconnecting()
            model.isResuming = true
            model.reconnect(self, to: model.relayTarget(hostID: hostID, name: hostName ?? String(localized: "A Mac")))
        } else {
            // The LAN-only case: the Mac is paired and not here yet. Stopping at the first attempt that found nothing would end a resume that has not failed.
            scheduleReconnect()
        }
    }

    /// The wait is a wall clock and the app is not running for most of it, so a phone put away mid-resume comes back with part of a rung spent. Called as the app comes to the front.
    /// Only where the Mac can be dialled from where it stands: otherwise cutting the wait short would spend the rung rather than skip it.
    func resumeWithoutWaiting() {
        guard reconnectTask != nil, let hostID else { return }
        let visible = model.hosts.contains { $0.id == hostID }
        // A remembered address counts as dialable: a phone coming to the front has stale Bonjour results.
        let remembered = model.rememberedLANHost(hostID) != nil
        let byRelay = model.allowsRelay && model.pins.hostIDs.contains(hostID)
        guard visible || remembered || byRelay else { return }
        stopReconnecting()
        resumeIfNeeded()
    }

    /// A resume gets the shorter ladder, chosen here because it must match the counter: `reconnectAttempt` indexes into whichever ladder is used.
    func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        // A Mac already given up on is not dialled again: the window can end an episode before the counter runs out, and the failures from the attempt it cut would start the ladder over.
        guard !hasGivenUpResuming else { return }
        // Not `isResumingAfterDrop`, which reads `isReconnecting`, only set below: at the moment of a drop it is false and the drop would get the slow ladder.
        let resuming = hasBeenReady && !userEndedDeliberately
        let delays = resuming
            ? SessionModel.resumeReconnectDelays
            : SessionModel.reconnectDelays
        // The clock starts at the first rung and is carried across every dial, so it measures the episode, not the attempt.
        if hasBeenReady, reconnectingSince == nil { reconnectingSince = Date() }
        guard reconnectAttempt < delays.count, !hasReconnectWindowPassed else {
            giveUpOnReconnecting()
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

        // The phone's network may have moved unnoticed (nothing was being put back) and a relay socket can hang for the whole silence watchdog. Asked here because this is the only place a wait begins, deferred a turn because the answer can dial. Only for a Mac being put back.
        if isResumingAfterDrop {
            Task { @MainActor [model] in model.considerNetworkChange() }
        }
    }

    /// See ``SessionModel/stopReconnecting()`` for why the counter is not cleared here.
    func stopReconnecting() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
    }

    /// Called from the poll this session runs while being put back, the one thing still ticking when a dial has stopped answering: every other end is reached by a failure arriving, and a Mac that never answers sends none.
    func giveUpAfterReconnectWindow() {
        guard hasReconnectWindowPassed else { return }
        sessionLog.error("no answer from the Mac in \(Int(SessionModel.reconnectWindow))s, giving up")
        giveUpOnReconnecting()
    }

    /// One end for both ways a ladder finishes: out of rungs, or out of time.
    private func giveUpOnReconnecting() {
        stopReconnecting()
        reconnectingSince = nil
        // A restoration that never got its answer ends like one that failed: the persisted request goes, so the next launch does not open this again.
        if !hasBeenReady, isComingBack {
            UserDefaults.standard.set(false, forKey: SessionModel.resumeKey)
        }
        // And the flag a cold launch set: nothing will dial this Mac again this launch, so the header would describe an attempt that no longer exists.
        isComingBack = false
        // Running out is when the app stops behaving like a session coming back: this flag turns the remote screen over to the picker. The banner is not re-posted because `SessionAwareness` refuses a repeat of the phase it is in.
        hasGivenUpResuming = true
        gaveUpAt = Date()
        // A dial still in flight is ended here; it reports `.disconnected`, which the guard at the top of ``scheduleReconnect()`` stops from arming another rung.
        connectTask?.cancel()
        connectTask = nil
        dialRace?.cancel()
        wire?.disconnect()
        wire = nil
        // The app started the attempt just cut, so the flag goes with it: left set, the user's next dial of any Mac would read as ours.
        model.clearResumingIfNothingIsUnderWay()
        // The screen is about to leave and no replacement stream will reuse its display, so this releases the attachment that non-deliberate teardown kept for the retry. A background Mac shares the active Mac's renderer and must not detach it.
        if isActive { renderer.detach() }
        // The Live Activity must be told directly: a ladder running out changes no phase, so `sessionMoved` never runs and the card would stay on Reconnecting. Only for the Mac on screen.
        if isActive {
            SessionActivity.shared.sessionDropped(
                hostName: hostName ?? String(localized: "the Mac"),
                startedAt: nil,
                path: Self.activityPath(connectionPath)
            )
        }
    }

    // MARK: - Asking this Mac for the picture, and for silence

    /// Never assumed: `false` is a Mac too old to have been asked, where the command means a dropped session rather than a stopped picture. See ``PicturePause/mayAsk(hostDeclared:)``.
    var hostSupportsVideoPause = false

    /// `nil` is not yet answered, or a Mac that cannot; either way every agent is shown.
    var hostSupportsAgentList = false
    var installedAgents: Set<String>?

    /// Never assumed: an older Mac cannot decode the request and would end the session. See ``AgentChatSupport/maySend(toHostDeclared:)``.
    var hostSupportsAgentChat = false

    var hostSupportsFileBrowser = false

    var hostSupportsAgentModelPicker = false
    var hostSupportsAgentPermissionModes = false
    var hostSupportsAgentUsage = false

    /// A Mac from before the list chats with the first two.
    var hostChatAgents: Set<String> = ["claude", "codex"]

    /// Made once per Mac connection and reused: every path, preview and upload is keyed by it as a terminal's browsing is keyed by the terminal's id, and a reconnect re-announces the same id.
    let browserID = UUID()

    /// Never assumed: an older Mac cannot decode the command, so sending it is a mid-session failure. See ``ClipboardImages/maySend(toHostDeclared:)``.
    var hostSupportsClipboardImages = false

    /// False for an older host, where the local banner remains required.
    var hostPushesTerminalAlertsWhileConnected = false

    /// The intent rather than rectangles, which go stale when the phone rotates (see ``MosaicGrid``). Per Mac: a session that comes back to a different one must not offer a mosaic of windows that are not there.
    var mosaicChoices: [MosaicChoice] = []

    /// On the session because the model outlives it: a rotation pending when a connection ended would be delivered to the next Mac.
    var mosaicViewportTask: Task<Void, Never>?

    /// On the session for the same reason: it is a question about this Mac's windows.
    var mosaicGapTask: Task<Void, Never>?

    /// A tile the Mac cannot capture looks like one it can: ScreenCaptureKit keeps listing a window it will not render, so the tap is the only way to learn it. Emptied by ``SessionModel/showMosaic(_:)``.
    var sourcesThatOpenedNothing: Set<String> = []

    var tileOpeningWatch: Task<Void, Never>?

    /// Must survive a rotation: ``mosaicLayout`` is built from the live screen size, so its identifier stops matching ``activeSourceID`` once the phone turns.
    var isAskingForMosaic = false

    /// Set whenever the session reaches `.ready`, including a reconnect: the fresh capture pipeline remembers nothing, and the Mac gives a new client about a second to say what it wants before defaulting to a display of its own (`VideoCoordinator.firstAskGrace`), so a mosaic not re-asked is replaced by a plain desktop. Consumed by the next catalogue. See ``MacSession/apply(_:)``.
    var pendingSourceReassertion = false

    var mosaicLayout: MosaicLayout? {
        MosaicGrid.layout(
            choices: mosaicChoices,
            viewport: mosaicViewport,
            tileAspect: mosaicTileAspect
        )
    }

    var mosaicTileAspect: Double { tileAspect(for: mosaicChoices) }

    /// The ask is built before ``mosaicChoices`` holds it, so shaping must be a function of the choices being asked for: read from the session, the same arrangement came out a different shape depending on which door asked (a restore used the fallback aspect). The median ignores one odd window; sources the catalogue cannot describe are left out.
    func tileAspect(for choices: [MosaicChoice]) -> Double {
        let aspects = choices
            .compactMap { catalog?.descriptor(for: $0.source)?.pixelSize }
            .filter { $0.width > 0 && $0.height > 0 }
            .map { Double($0.width / $0.height) }
            .sorted()
        guard !aspects.isEmpty else { return MosaicGrid.windowAspect }
        // Clamped: a 40-pixel strip of a window is capturable but a bad thing to build a grid from.
        return min(max(aspects[aspects.count / 2], 0.5), 3.0)
    }

    /// The shape comes from the interface and the pixels from the screen: `bounds` does not change when the phone turns, only which number is the width, and iOS takes about two seconds to say so. Read from the window scene, not `UIScreen.main`.
    var mosaicViewport: CGSize {
        guard let scene = DeviceScene.window else {
            return CGSize(width: 1280, height: 720)
        }
        let bounds = scene.screen.bounds
        let scale = scene.screen.scale
        let longer = max(bounds.width, bounds.height) * scale
        let shorter = min(bounds.width, bounds.height) * scale
        return DeviceScene.isLandscape
            ? CGSize(width: longer, height: shorter)
            : CGSize(width: shorter, height: longer)
    }

    /// Recorded when the Mac answers, not when the app asks: it takes a second or two to build the new tiles, and everything drawn over the picture must agree with it. See ``MacSession/apply(video:)``.
    var pictureMosaicLayout: MosaicLayout?

    /// Frozen because ``mosaicLayout`` is rebuilt from the live screen and catalogue on every read, so reading it when the Mac answers could record an arrangement it never built. Set by ``SessionModel/selectSource(_:)``.
    var askedMosaicLayout: MosaicLayout?

    var isShowingMosaic: Bool { pictureMosaicLayout != nil }

    /// Never assumed, more than anywhere else: an un-updated Mac cannot decode a capture source and sending it ends the session. See ``MosaicSupport/maySend(hostDeclared:)``.
    var hostSupportsMosaic = false

    /// Gated: the request goes out when the Apps panel opens, and a Mac that cannot decode it ends the session. See ``SourceThumbnailSupport/maySend(hostDeclared:)``.
    var hostSupportsSourceThumbnails = false

    var hostSupportsDeviceOrientation = false

    var hostSupportsVirtualDisplayManagement = false

    /// Not the same as the picture being stopped: a sleeping screen, a failed stream and a pause this end requested look alike, and only the third may be undone here.
    var picturePaused = false

    /// The request goes out here and frames come back to the renderer, so this is the only place both ends of the interval are visible. Reported into notes and Diagnostics.
    var pictureResumedAt: Date?
    var pictureResumeBaselineFrames: Int?
    var lastResumeMilliseconds: Double?

    var autoQualityPolicy = AutoQualityPolicy(path: .lan)
    var lastAutoDroppedFrames = 0

    /// Per Mac: one Mac's diagnosis must not carry sentences about another.
    var notes: [String] = []

    // MARK: - Session history

    /// One number for a live session and its record, which is written to `UserDefaults` and read at launch, so it is a size as much as a limit.
    static let sessionLogLimit = 40

    var activeSessionHistoryID: UUID?
    var activeSessionHistoryStartedAt: Date?
    var activeSessionBytes: Int64 = 0
    var lastBandwidthSampleBytes: Int64 = 0
    var activeSessionLogs: [String] = []

    /// Held as the record's identity and totals, not its index: the list moves under anything positional. See ``SessionContinuation``.
    var activeSessionContinuation: SessionContinuation?

    var isActive: Bool { model.activeSessionID == id }

    /// The second half is why this is not ``SessionModel/isSessionOnScreen``: a Picture in Picture window is somebody still watching from outside the app, so stepping back to the picker must not freeze it. See ``SessionModel/stepAwayFromSession()``.
    var isWatched: Bool { model.isSessionOnScreen || SessionPiP.shared.isActive }

    /// Being the Mac on screen decides whose sound plays, else two Macs open at once are two audio engines into one pair of ears (a Mac behind the one on screen is silent). Being watched decides whether anything is heard: a session the user stepped away from is still connected with its player. See ``isWatched``.
    var shouldPlayAudio: Bool { isActive && isWatched && model.playsHostAudio }

    /// Called when a config arrives and when the active Mac changes: a player built for the Mac on screen keeps playing after the user looks away unless told.
    func refreshAudioMuteState() {
        audioPlayer?.isMuted = !shouldPlayAudio
    }

    // MARK: - Clipboard

    /// A payload, not a string, so a screenshot copied on the Mac arrives as readily as text. See ``ClipboardPayload``.
    var hostClipboard: ClipboardPayload?

    var clipboardPulling = false

    // MARK: - Audio

    var audioPlayer: RemoteAudioPlayer?

    // MARK: - Terminals

    var terminals: [RemoteTerminal] = []
    var selectedTerminalID: UUID?

    /// Sent as the shell's first line when the Mac says it exists. See ``createTerminal(inDirectory:)``.
    var pendingTerminalDirectory: String?

    /// So an unchanged list is not re-sent on every keystroke a shell prints.
    var publishedWork: [SessionActivityAttributes.ContentState.Work]?

    /// Capped: a Lock Screen has room for a few lines and the card's own line says how many Macs are open.
    func workItems() -> [SessionActivityAttributes.ContentState.Work] {
        var work: [SessionActivityAttributes.ContentState.Work] = []
        for session in agentSessions {
            let folder = session.directory.split(separator: "/").last.map(String.init)
            switch session.state {
            case .awaitingApproval:
                work.append(.init(name: session.title, symbol: "questionmark.bubble", state: .waiting, detail: folder))
            case .working:
                work.append(.init(
                    name: session.title,
                    symbol: TerminalAgent.all.first { $0.id == session.agentID }?.symbol ?? "sparkles",
                    state: .live,
                    detail: folder
                ))
            case .failed:
                work.append(.init(name: session.title, symbol: "exclamationmark.triangle", state: .failed, detail: folder))
            case .idle, .exited:
                break
            }
        }
        for terminal in terminals where terminal.isRunning {
            if terminal.attention != nil {
                work.append(.init(name: terminal.name, symbol: "lock", state: .waiting))
            } else if terminal.failure != nil {
                work.append(.init(name: terminal.name, symbol: "exclamationmark.triangle", state: .failed))
            } else {
                work.append(.init(name: terminal.name, symbol: "terminal", state: .live))
            }
        }
        return Array(work.sorted { $0.state.isWaiting && !$1.state.isWaiting }.prefix(4))
    }

    /// Called from every terminal and agent event rather than the screens: the card matters when nobody is looking at the app.
    func publishWork() {
        guard model.activeSessionID == id else { return }
        let work = workItems()
        guard work != publishedWork else { return }
        publishedWork = work
        SessionActivity.shared.workChanged(work)
    }

    /// A terminal has no id until the Mac answers, so nothing can move to it at the tap. Left here for the panel to take, and nil otherwise: a terminal arriving for another reason must not be dragged in front.
    var newTerminalID: UUID?

    // MARK: - Agent chats

    var agentSessions: [RemoteAgentSession] = []
    /// Messages typed while a turn runs: the CLIs take one question at a time, so the rest wait here and go as each turn ends.
    var agentQueues: [UUID: AgentPromptQueue] = [:]
    /// The chat list's own copy, rebuilt at most a few times a second: see ``AgentCardDigest``.
    var agentCards: [AgentCardDigest] = []
    @ObservationIgnored var agentCardsTask: Task<Void, Never>?
    var terminalCards: [TerminalCardDigest] = []
    @ObservationIgnored var terminalCardsTask: Task<Void, Never>?
    /// Chats whose full history has been asked for, so a stream of events does not ask again for each one.
    var agentHistoryRequested: Set<UUID> = []
    var selectedAgentSessionID: UUID?

    var newAgentSessionID: UUID?
    var agentPicker = AgentPickerState()

    /// A PTY gives a byte stream with no marker for where one command's output starts, so the only link is that it arrived right after one.
    var lastSentCommand: String?
    var lastSentAt: Date?

    // MARK: - File browsing

    /// Held, not asked per appearance, so stepping into a folder and back out is instant. See ``RemoteDirectoryKey``.
    var directories: [RemoteDirectoryKey: RemoteDirectory] = [:]

    var browsingPaths: [UUID: String] = [:]

    var pendingDirectories: Set<RemoteDirectoryKey> = []

    var browseFailures: [RemoteDirectoryKey: String] = [:]

    var filePreview: RemoteFilePreview?

    /// A terminal has no id until the Mac says it made one, so the command is remembered until ``apply(terminal:)`` sees the shell. One at a time: a second tap in that window means the second file, not both.
    var pendingRun: String?

    struct FileWrite: Equatable {
        /// A save reads the file back so the editor shows what is on disk; an upload asks for the folder again so the file appears. Otherwise the same operation, hence one record.
        enum Door { case save, upload }

        let door: Door
        /// What the Mac's answer is matched on, since it names the file it wrote.
        let path: String
    }

    /// By terminal, not one flag: two can be in the air at once and a single flag hands the first answer to whichever transfer asked second.
    var writes: [UUID: FileWrite] = [:]

    /// Kept apart by door: a failed save is a file to correct, a failed upload a file to choose again. Read through ``saveFailure(sessionID:)`` and ``uploadFailure(sessionID:)``.
    var saveFailures: [UUID: String] = [:]
    var uploadFailures: [UUID: String] = [:]

    struct FileChange: Equatable {
        /// Held rather than only the path: the answer says what happened but not what was asked, and a rename's path is built from both.
        let operation: RemoteFileOperation
        /// The file's own path for a rename, not the one it becomes: the Mac's answer echoes what it was sent, and is matched on this.
        let path: String
    }

    /// A folder is a sequence of the existing operations; the protocol does not know about folders. One per shell, since the Mac answers an operation by naming the path it was given.
    var folderUploads: [UUID: FolderUpload] = [:]

    /// One per terminal: the Mac answers a change by naming the path, so two operations through one shell would match one remembered request. The entry also disables the controls.
    var changes: [UUID: FileChange] = [:]

    /// Not in ``uploadFailures`` or ``browseFailures``: a browse failure replaces the list with a full-panel state, which a failed rename must not do; this one is drawn above the list.
    var changeFailures: [UUID: String] = [:]

    // MARK: - The picture's on/off switch

    /// Touches nothing else: the control channel, shells, clipboard and the keep-awake assertion all survive. Silent for a Mac that cannot take it.
    func setPicturePaused(_ paused: Bool) {
        guard PicturePause.mayAsk(hostDeclared: hostSupportsVideoPause) else { return }
        guard phase.holdsSession, paused != picturePaused else { return }
        picturePaused = paused
        send(.setVideoEnabled(!paused))

        if paused {
            pictureResumedAt = nil
            pictureResumeBaselineFrames = nil
        } else {
            // Taken before the frame arrives, the only moment it can be: the renderer's total when the ask went out is what the first frame back is measured from.
            pictureResumedAt = Date()
            pictureResumeBaselineFrames = renderer.currentSnapshot.framesEnqueued
            lastResumeMilliseconds = nil
        }
    }

    /// Called from the poll, not the event path, because the frame that answers may not touch the main actor. A count that moved in either direction counts: backwards is the renderer's total resetting.
    func measureResumeIfNeeded(_ snapshot: VideoRenderer.Snapshot) {
        guard let resumedAt = pictureResumedAt, let baseline = pictureResumeBaselineFrames else { return }
        guard snapshot.framesEnqueued != baseline else { return }

        pictureResumedAt = nil
        pictureResumeBaselineFrames = nil
        let milliseconds = Date().timeIntervalSince(resumedAt) * 1000
        lastResumeMilliseconds = milliseconds
        append(note: String(localized: "Picture back \(Int(milliseconds.rounded())) ms after asking for it"))
    }

    // MARK: - Sending

    /// Everything goes through the session's coalescer, so the rules about what may be merged and what must never be dropped live in one place.
    func send(_ command: RemoteCommand) {
        wire?.send(command)
    }

    // MARK: - Quality

    var isAutomaticQuality: Bool { model.streamQuality == .auto }

    var autoQualityPath: AutoQualityPolicy.Path {
        switch connectionPath {
        case .lan: return .lan
        case .relay: return .relay
        case .direct, nil: return .direct
        }
    }

    /// Uncapped on the direct path for every plan: two devices on one network spend nobody's bandwidth. A relayed session is the operator's link, and ``PlanCapability/highBitrate`` buys 20 Mbps there instead of 8.
    var videoCeiling: AutoQualityPolicy.Tier {
        guard autoQualityPath == .relay else { return .high }
        return model.storeManager.access.includes(.highBitrate) ? .high : .medium
    }

    /// Turning manual on lands on the level picked last or the policy's current rate, so the picture does not jump.
    func setAutomaticQuality(_ automatic: Bool) {
        setStreamQuality(automatic ? .auto : (model.lastManualQuality ?? StreamQuality(autoQualityPolicy.tier)))
    }

    /// The save makes the Settings row and this one the same setting.
    func setStreamQuality(_ quality: StreamQuality) {
        // The one rung a plan can be short of, only while bytes are carried. Asking opens the plans rather than being quietly capped, since a silently soft picture reads as broken. High on a direct session is not gated: see ``videoCeiling``.
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

    /// Every arrival, not only an automatic one: the Mac clears `requestedBitrateKbps` when the video peer closes and falls back to its top rate, so an unsent manual level leaves the phone reading Low while watching 20 Mbps. The stored token is read, not ``SessionModel/streamQuality``, which Settings can leave stale.
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

        // On the control channel the host holds the rate down on purpose, so asking for more would break its ceiling: see ``VideoCoordinator/effectiveBitrateKbps``. This end stops driving the number but still measures.
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
        append(note: String(localized: "Auto quality changed to \(tier.bitrateKbps / 1_000) Mbps"))
    }

    // MARK: - The captured picture

    var activeSourceTitle: String? {
        // A mosaic is named before the catalogue is asked, since the catalogue has no row for it, and from the ask as well as the answer, so the pill names it as soon as it is asked for.
        if isAskingForMosaic, let layout = mosaicLayout {
            return String(localized: "\(layout.tiles.count) windows")
        }
        guard let activeSourceID,
              let descriptor = catalog?.all.first(where: { $0.id == activeSourceID })
        else { return nil }
        return descriptor.title
    }

    /// Answered from what the picture is rather than what was asked, so a mosaic the Mac refuses to build does not leave the arrangement unreachable; the ask counts too, so it is not offered while the canvas is being built.
    var canReturnToMosaic: Bool {
        mosaicLayout != nil && !isShowingMosaic && !isAskingForMosaic
    }

    /// The picture on screen, not the one being asked for: everything drawn over the picture is measured against this. ``picture`` first, the catalogue second. See ``capturePointSize``.
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

    /// Halves the pixel size, assuming a 2x backing store: the protocol carries pixels, not the point-to-pixel scale. It only scales a relative nudge, so a wrong factor changes cursor speed, not where it lands.
    var capturePointSize: CGSize {
        guard let pixels = capturePixelSize else { return CGSize(width: 1512, height: 982) }
        return CGSize(width: pixels.width / 2, height: pixels.height / 2)
    }

    /// The catalogue is the only thing that says what a source is, so it decides whether one can change size on its own; a source with no entry is unknown. See ``PictureIdentity/change(to:)``.
    func pictureIdentity(of config: VideoStreamConfig) -> PictureIdentity {
        PictureIdentity.forStream(
            config,
            catalog: catalog,
            // The arrangement as well as its name: a mosaic has no catalogue row.
            source: askedMosaicLayout.map { CaptureSource.mosaic($0) }
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
