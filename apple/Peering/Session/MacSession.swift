import Foundation
import PeeringKit
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
    typealias ConnectionPath = PeeringKit.ConnectionPath

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

    /// Why ``phase`` failed, when the wording could be chosen here. The picker reads it instead of searching the sentence.
    var failureCause: ClientSession.FailureCause?

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

    var lastFrameSample: (count: Int, at: ContinuousClock.Instant)?
    var framesFlowingPolls = 0
    /// Chats seen working or asking since this connection began: only those can have "finished", since an idle chat nobody ran is not news.
    var agentChatsSeenBusy: Set<UUID> = []

    var isVideoStreaming = false

    /// Sticky, unlike ``isVideoStreaming``, which is false both before the first config and while the user has paused: only the first has nothing on screen to interrupt, so only a sticky flag may allow a relay-to-LAN handover. See ``SessionModel/apply(_:)``'s `.updated`.
    var hasHadPicture = false

    /// `.control` means the Mac's network is not letting video through and the session has fallen back. See ``VideoFallbackPolicy``.
    var videoTransport: VideoTransport = .primary

    var videoPoll: Task<Void, Never>?
    /// Retained so ending or replacing the session also cancels an in-flight relay WebSocket, not only the TCP socket.
    var connectTask: Task<Void, Never>?

    var dialRace: DialRace?

    /// Set once and never cleared: the object is one attempt at one Mac, and everything that must know the user meant it (retry ladder, screens asking whether it is being put back) reads it long after the transition. Clearing it left a Quit showing "reconnecting" until tapped twice.
    /// Per Mac: `disconnect()` ends every Mac at once, and with one shared flag the first consumed it and the rest read as dropped.
    var userEndedDeliberately = false

    // MARK: - Coming back after a drop

    /// Set when the retry ladder runs out; cleared when a session is up again.
    var hasGivenUpResuming = false

    var gaveUpAt: MonotonicStamp?

    /// The one resume a session cannot recognise on its own: a cold launch has no object to carry `hasBeenReady` from (iOS killed the process), so the intent arrives with the dial and is put here by ``SessionModel/connect(to:replacing:)``.
    var isComingBack = false

    var isReconnecting = false

    /// Per Mac: with a shared counter the second Mac's failure resets the first's backoff, so a Mac that is switched off is dialled every second forever.
    var reconnectAttempt = 0
    var reconnectTask: Task<Void, Never>?

    /// Carried across a dial like ``hasBeenReady`` and ``reconnectAttempt``, since each rung builds a new object. See ``SessionModel/reconnectWindow``.
    var reconnectingSince: ContinuousClock.Instant?

    /// Carried across a retry like the facts above. See ``SessionTelemetry``.
    var telemetry = SessionTelemetry()

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

    /// Set whenever the session reaches `.ready`, including a reconnect: the fresh capture pipeline remembers nothing, and the Mac gives a new client a moment (a third of a second at most) to say what it wants before defaulting to a display of its own (`VideoCoordinator.firstAskGrace`), so a mosaic not re-asked is replaced by a plain desktop. Consumed by the next catalogue. See ``MacSession/apply(_:)``.
    var pendingSourceReassertion = false

    /// Recorded when the Mac answers, not when the app asks: it takes a second or two to build the new tiles, and everything drawn over the picture must agree with it. See ``MacSession/apply(video:)``.
    var pictureMosaicLayout: MosaicLayout?

    /// Frozen because ``mosaicLayout`` is rebuilt from the live screen and catalogue on every read, so reading it when the Mac answers could record an arrangement it never built. Set by ``SessionModel/selectSource(_:)``.
    var askedMosaicLayout: MosaicLayout?

    /// Never assumed, more than anywhere else: an un-updated Mac cannot decode a capture source and sending it ends the session. See ``MosaicSupport/maySend(hostDeclared:)``.
    var hostSupportsMosaic = false

    /// Gated: the request goes out when the Apps panel opens, and a Mac that cannot decode it ends the session. See ``SourceThumbnailSupport/maySend(hostDeclared:)``.
    var hostSupportsSourceThumbnails = false

    var hostSupportsDeviceOrientation = false

    var hostSupportsVirtualDisplayManagement = false

    /// Not the same as the picture being stopped: a sleeping screen, a failed stream and a pause this end requested look alike, and only the third may be undone here.
    var picturePaused = false

    /// The request goes out here and frames come back to the renderer, so this is the only place both ends of the interval are visible. Reported into notes and Diagnostics.
    var pictureResumedAt: MonotonicStamp?
    var pictureResumeBaselineFrames: Int?
    var lastResumeMilliseconds: Double?

    var autoQualityPolicy = AutoQualityPolicy(path: .lan)
    var lastAutoDroppedFrames = 0

    /// Per Mac: one Mac's diagnosis must not carry sentences about another.
    var notes: [String] = []

    // MARK: - Session history

    /// One number for a live session and its record, which is written to `UserDefaults` and read at launch, so it is a size as much as a limit.
    static let sessionLogLimit = 80

    var activeSessionHistoryID: UUID?
    var activeSessionHistoryStartedAt: Date?
    var activeSessionBytes: Int64 = 0
    var lastBandwidthSampleBytes: Int64 = 0
    var activeSessionLogs: [String] = []
    /// Lines logged before the session is ready, filed with it once it is.
    var preReadyLogs: [String] = []
    var lastLatencyLogAt: Date?

    /// Held as the record's identity and totals, not its index: the list moves under anything positional. See ``SessionContinuation``.
    var activeSessionContinuation: SessionContinuation?

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
    /// Approvals the Mac has reported resolved on this connection; an answer is delivered only once its id is here. See ``ApprovalAnswerPolicy``.
    @ObservationIgnored var resolvedApprovalIDs: Set<String> = []
    /// The chat list's own copy, rebuilt at most a few times a second: see ``AgentCardDigest``.
    var agentCards: [AgentCardDigest] = []
    @ObservationIgnored var agentPauses = AgentPauseClock()
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
    var agentChangesAskedAt: [UUID: MonotonicStamp] = [:]
    /// A commit or push the Mac has not answered yet, and the last answer, per chat.
    var agentGitBusy: [UUID: AgentGitOperation] = [:]
    var agentGitResults: [UUID: AgentGitResult] = [:]

    /// A PTY gives a byte stream with no marker for where one command's output starts, so the only link is that it arrived right after one.
    var lastSentCommand: String?
    var lastSentAt: MonotonicStamp?

    // MARK: - File browsing

    /// Held, not asked per appearance, so stepping into a folder and back out is instant. See ``RemoteDirectoryKey``.
    var directories: [RemoteDirectoryKey: RemoteDirectory] = [:]

    var browsingPaths: [UUID: String] = [:]

    var pendingDirectories: Set<RemoteDirectoryKey> = []

    var browseFailures: [RemoteDirectoryKey: String] = [:]

    var filePreview: RemoteFilePreview?

    /// A terminal has no id until the Mac says it made one, so the command is remembered until ``apply(terminal:)`` sees the shell. One at a time: a second tap in that window means the second file, not both.
    var pendingRun: String?

    /// By terminal, not one flag: two can be in the air at once and a single flag hands the first answer to whichever transfer asked second.
    var writes: [UUID: FileWrite] = [:]

    /// Kept apart by door: a failed save is a file to correct, a failed upload a file to choose again. Read through ``saveFailure(sessionID:)`` and ``uploadFailure(sessionID:)``.
    var saveFailures: [UUID: String] = [:]
    var uploadFailures: [UUID: String] = [:]

    /// The send window of the transfer in the air per terminal, kept so the cancel button can reach it.
    var uploadWindows: [UUID: SendWindow] = [:]

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
}
