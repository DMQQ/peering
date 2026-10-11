import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import os

let sessionLog = Logger(subsystem: "pl.dmq.peering", category: "session")

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
    var badConnectionWarning = BadConnectionWarning()

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

    /// Set when the retry ladder runs out; cleared when a session is up again.
    var hasGivenUpResuming = false

    var gaveUpAt: Date?

    /// The one resume a session cannot recognise on its own: a cold launch has no object to carry `hasBeenReady` from (iOS killed the process), so the intent arrives with the dial and is put here by ``SessionModel/connect(to:replacing:)``.
    var isComingBack = false

    var isReconnecting = false

    /// Per Mac: with a shared counter the second Mac's failure resets the first's backoff, so a Mac that is switched off is dialled every second forever.
    var reconnectAttempt = 0
    var reconnectTask: Task<Void, Never>?

    /// Carried across a dial like ``hasBeenReady`` and ``reconnectAttempt``, since each rung builds a new object. See ``SessionModel/reconnectWindow``.
    var reconnectingSince: Date?

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
    var hostSupportsAgentSessionImport = false
    var hostSupportsAgentPause = false

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

    var mosaicTileAspect: Double { tileAspect(for: mosaicChoices) }

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
    var agentHistoryRequests = AgentHistoryRequests()
    var selectedAgentSessionID: UUID?

    var newAgentSessionID: UUID?
    var agentPicker = AgentPickerState()
    /// Nil until the Mac has answered; the terminal conversations it offers to continue.
    var resumableSessions: [AgentResumableSession]?
    /// What git said about each chat's folder, and the chats still waiting for that answer.
    var agentChanges: [UUID: AgentChangesReport] = [:]
    var agentChangesLoading: Set<UUID> = []
    var agentChangesAskedAt: [UUID: Date] = [:]
    /// A commit or push the Mac has not answered yet, and the last answer, per chat.
    var agentGitBusy: [UUID: AgentGitOperation] = [:]
    var agentGitResults: [UUID: AgentGitResult] = [:]

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

    /// One download at a time per browser: the file or zip being fetched, a finished one waiting to be handed to the share sheet, and why one failed.
    var downloads: [UUID: FileDownload] = [:]
    var finishedDownloads: [UUID: URL] = [:]
    var finishedVideos: [UUID: (path: String, url: URL)] = [:]
    var downloadFailures: [UUID: String] = [:]

    /// One per terminal: the Mac answers a change by naming the path, so two operations through one shell would match one remembered request. The entry also disables the controls.
    var changes: [UUID: FileChange] = [:]

    /// Not in ``uploadFailures`` or ``browseFailures``: a browse failure replaces the list with a full-panel state, which a failed rename must not do; this one is drawn above the list.
    var changeFailures: [UUID: String] = [:]


    // MARK: - Sending

    /// Everything goes through the session's coalescer, so the rules about what may be merged and what must never be dropped live in one place.
    func send(_ command: RemoteCommand) {
        wire?.send(command)
    }

    // MARK: - Quality

    var isAutomaticQuality: Bool { model.streamQuality == .auto }


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
