import Foundation

/// How freely an agent may act without asking, as the phone can set it.
///
/// Not every agent has all three: a session lists the ones its CLI can do in ``AgentSessionInfo/permissionModes``.
public enum AgentPermissionMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// Asks before an edit or a command.
    case manual
    /// Edits go through; anything riskier still asks, or is refused.
    case acceptEdits
    /// Nothing asks.
    case auto
}

/// A chat session with a coding agent, as the Mac describes it in a listing.
///
/// Identified stably while the control client is away, so a reconnecting phone can reattach.
public struct AgentSessionInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The catalogue command the session runs: `"claude"`, `"codex"` or `"opencode"`.
    public let agentID: String
    /// What the tab shows: the agent's name and the folder it works in, resolved by the host.
    public let title: String
    public let directory: String
    public let state: AgentSessionState
    /// The index of the last stream event the Mac holds, so a reattaching phone asks only for what it missed.
    public let lastIndex: UInt64
    /// What the session is running, as the CLI resolved it. Optional: the two CLIs name their default differently.
    public let model: String?
    /// The mode the session is in, and the ones its CLI can be put in. Both nil from a Mac that
    /// predates the toggle, which is how the phone knows not to draw it.
    public let permissionMode: AgentPermissionMode?
    public let permissionModes: [AgentPermissionMode]?
    public let createdAt: Date

    public init(
        id: UUID,
        agentID: String,
        title: String,
        directory: String,
        state: AgentSessionState,
        lastIndex: UInt64,
        model: String? = nil,
        permissionMode: AgentPermissionMode? = nil,
        permissionModes: [AgentPermissionMode]? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.directory = directory
        self.state = state
        self.lastIndex = lastIndex
        self.model = model
        self.permissionMode = permissionMode
        self.permissionModes = permissionModes
        self.createdAt = createdAt
    }
}

/// What a session is doing: a fact about the turn, not the process.
public enum AgentSessionState: String, Codable, Equatable, Sendable {
    case idle
    case working
    /// A turn is blocked on the user's answer to an approval prompt.
    case awaitingApproval
    /// The CLI has ended. The transcript is still there to read.
    case exited
    /// Something ended the session that was not the user.
    case failed
}

/// The user's verdict on one approval prompt.
///
/// `choose` answers question-style asks (Claude's `AskUserQuestion`): it travels back as an allow whose `updatedInput` holds the answer.
public enum AgentApprovalDecision: Codable, Equatable, Sendable {
    case allow
    case deny
    case choose(String)
}

public struct AgentToolOption: Codable, Equatable, Sendable {
    public let label: String
    public let detail: String?

    public init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }
}

/// One tool call, in the shape both CLIs' events are normalised into.
///
/// ``name`` is an open string on purpose: a new tool in a new CLI release must draw a generic card, not fail a decode.
public struct AgentToolCall: Codable, Equatable, Sendable {
    public let id: String
    /// The CLI's raw tool name (`"Bash"`, `"Edit"`, `"command_execution"`).
    public let name: String
    /// What the card's title says, chosen by the adapter that knows the CLI.
    public let title: String
    /// The command, path or pattern shown under the title (the question itself for a question ask).
    public let detail: String?
    public let filePath: String?
    public let diff: String?
    public let options: [AgentToolOption]?

    public init(
        id: String,
        name: String,
        title: String,
        detail: String? = nil,
        filePath: String? = nil,
        diff: String? = nil,
        options: [AgentToolOption]? = nil
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.detail = detail
        self.filePath = filePath
        self.diff = diff
        self.options = options
    }
}

/// What one finished turn cost, as far as the CLI would say; fields are optional because the CLIs report different things.
public struct AgentTurnSummary: Codable, Equatable, Sendable {
    public let ok: Bool
    public let stopped: Bool
    public let costUSD: Double?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let duration: TimeInterval?
    public let model: String?

    public init(
        ok: Bool,
        stopped: Bool = false,
        costUSD: Double? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        duration: TimeInterval? = nil,
        model: String? = nil
    ) {
        self.ok = ok
        self.stopped = stopped
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.duration = duration
        self.model = model
    }
}

/// One thing that happened in an agent session, in the one shape both CLI adapters produce.
///
/// The index is monotonic per session: the client applies an event only if its index is greater than the last applied, so a replay racing live output is exact. Indices start at 1; `since: 0` means everything.
public struct AgentStreamEvent: Codable, Equatable, Sendable {
    public let index: UInt64
    public let payload: Payload

    public init(index: UInt64, payload: Payload) {
        self.index = index
        self.payload = payload
    }

    public enum Payload: Codable, Equatable, Sendable {
        /// The CLI is up. ``cliSessionID`` is the id to resume with after a restart, nil if none yet.
        case sessionReady(agentID: String, cliSessionID: String?, model: String?, directory: String)
        /// What the user said, from the CLI's own echo where it has one, so a replay rebuilds the conversation.
        case userPrompt(text: String)
        case turnStarted
        /// A piece of the reply as it arrives. Coalesced by the host rather than sent per token.
        case textDelta(text: String)
        /// The reply block, whole and authoritative: the client replaces what the deltas built.
        case textFinal(text: String)
        case toolStarted(call: AgentToolCall)
        /// A tool call's outcome. ``output`` is truncated by the host; ``truncated`` says so.
        case toolFinished(callID: String, ok: Bool, output: String?, truncated: Bool)
        case approvalRequested(approvalID: String, call: AgentToolCall, reason: String?)
        case approvalResolved(approvalID: String, decision: AgentApprovalDecision)
        case turnFinished(summary: AgentTurnSummary)
        /// Worth a line in the transcript but not a failure.
        case notice(text: String)
        case failure(message: String)
        case sessionExited(status: Int32)
    }
}

/// Requests sent by an authenticated client for an agent chat session.
///
/// Sent only to a Mac that declared ``ServerHello/supportsAgentChat``: an older Mac fails the session on an undecodable request.
public enum AgentRequest: Codable, Equatable, Sendable {
    /// Every session this client owns, as summaries; transcripts come via ``history(sessionID:since:)``.
    case list
    /// Everything after ``since``, in as many ``AgentEvent/replay(sessionID:events:isLast:truncatedAtFront:)``
    /// chunks as it takes.
    case history(sessionID: UUID, since: UInt64)
    /// A new chat. ``directory`` is the folder the agent works in; nil means the Mac's home folder,
    /// the one path the phone cannot work out for itself.
    case start(agentID: String, directory: String?)
    case prompt(sessionID: UUID, text: String)
    /// The user's answer to one approval prompt. A second answer for the same id is ignored.
    case approval(sessionID: UUID, approvalID: String, decision: AgentApprovalDecision)
    /// Stop the turn in flight. The session stays; the next prompt starts a new turn.
    case interrupt(sessionID: UUID)
    /// What the session runs from now on; `nil` restores the CLI's default (Claude changes model in-process, Codex per turn).
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentModelPicker``.
    case setModel(sessionID: UUID, model: String?)
    /// How freely the session may act from now on. Sent only to a Mac that declared
    /// ``ServerHello/supportsAgentPermissionModes``.
    case setPermissionMode(sessionID: UUID, mode: AgentPermissionMode)
    case close(sessionID: UUID)
    /// One folder's contents for the chat picker; needs no shell, unlike ``TerminalRequest/listDirectory(sessionID:path:)``.
    case browse(path: String?)
}

public enum AgentEvent: Codable, Equatable, Sendable {
    case snapshot([AgentSessionInfo])
    case created(AgentSessionInfo)
    case stream(sessionID: UUID, event: AgentStreamEvent)
    /// A chunk of the history ``AgentRequest/history(sessionID:since:)`` asked for; chunked because a conversation is megabytes on a shared channel.
    /// ``truncatedAtFront`` says the Mac's buffer no longer holds the start, so the client can say so.
    case replay(sessionID: UUID, events: [AgentStreamEvent], isLast: Bool, truncatedAtFront: Bool)
    case directory(path: String, entries: [RemoteDirectoryEntry], truncated: Bool)
    case browseFailure(path: String, message: String)
    case closed(sessionID: UUID)
    /// The model the session now runs, sent when the picker changes it and whenever the CLI
    /// itself announces one. `nil` is the CLI's default.
    case modelChanged(sessionID: UUID, model: String?)
    /// The mode the session is now in, once the CLI has taken it. Sent only to a client that
    /// declared ``ClientHello/supportsAgentPermissionModes``.
    case permissionModeChanged(sessionID: UUID, mode: AgentPermissionMode)
    case failed(sessionID: UUID?, message: String)
}

/// Whether agent chat traffic may cross a session, in both directions.
///
/// As with ``ClipboardImages``: an older peer cannot decode these kinds and fails the session, so each end reads the other's declaration first. Only an explicit `true` counts: `nil` is a peer built before the field.
public enum AgentChatSupport {
    /// Whether a client may send ``AgentRequest`` to this Mac.
    public static func maySend(toHostDeclared declared: Bool?) -> Bool {
        declared == true
    }

    /// Whether a Mac may send ``AgentEvent`` to this client.
    public static func mayReceive(clientDeclared declared: Bool?) -> Bool {
        declared == true
    }
}
