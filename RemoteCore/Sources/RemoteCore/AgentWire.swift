import Foundation

/// A chat session with a coding agent, as the Mac describes it in a listing.
///
/// The counterpart of ``TerminalSessionInfo``: identified stably while the control client is away,
/// so a phone that reconnects can reattach to a session that kept working.
public struct AgentSessionInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The catalogue command the session runs: `"claude"`, `"codex"` or `"opencode"`.
    public let agentID: String
    /// What the tab shows: the agent's name and the folder it works in, resolved by the host.
    public let title: String
    public let directory: String
    public let state: AgentSessionState
    /// The index of the last stream event the Mac holds for this session.
    ///
    /// Carried so a reattaching phone can ask for what it missed rather than all of it:
    /// ``AgentRequest/history(sessionID:since:)`` replays from here.
    public let lastIndex: UInt64
    /// What the session is running, as the CLI resolved it: the model picker's answer, and what
    /// it shows before anything has been changed. Optional, because the two CLIs name their
    /// default model differently and a session that has not said yet has none.
    public let model: String?
    public let createdAt: Date

    public init(
        id: UUID,
        agentID: String,
        title: String,
        directory: String,
        state: AgentSessionState,
        lastIndex: UInt64,
        model: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.directory = directory
        self.state = state
        self.lastIndex = lastIndex
        self.model = model
        self.createdAt = createdAt
    }
}

/// What a session is doing, which is a fact about the turn rather than about the process:
/// neither CLI keeps one process per conversation alive the same way, and both spend most of
/// their life between turns with nothing running.
public enum AgentSessionState: String, Codable, Equatable, Sendable {
    /// Started, and no turn in flight.
    case idle
    /// A turn is running.
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
/// `choose` is for the asks that are questions rather than permissions: Claude's `AskUserQuestion`
/// carries a list of options and the answer is one of them, which is verified to travel back as an
/// allow whose `updatedInput` holds the question's answer. A verdict and its payload are one value
/// so a choice cannot arrive without the thing chosen.
public enum AgentApprovalDecision: Codable, Equatable, Sendable {
    case allow
    case deny
    case choose(String)
}

/// One option of a question-style ask.
public struct AgentToolOption: Codable, Equatable, Sendable {
    public let label: String
    /// The option's own explanation, when the CLI offers one.
    public let detail: String?

    public init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }
}

/// One tool call, in the shape both CLIs' events are normalised into.
///
/// ``name`` is the CLI's own tool name and is deliberately an open string: a new tool in a new CLI
/// release must draw a generic card, not fail a decode.
public struct AgentToolCall: Codable, Equatable, Sendable {
    public let id: String
    /// The CLI's raw tool name (`"Bash"`, `"Edit"`, `"command_execution"`).
    public let name: String
    /// What the card's title says, chosen by the adapter that knows the CLI.
    public let title: String
    /// The command, path or pattern the card shows under its title. For a question ask, the
    /// question itself.
    public let detail: String?
    public let filePath: String?
    /// A unified diff, when the CLI gives one for this call.
    public let diff: String?
    /// The choices of a question-style ask, empty for everything else.
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

/// What one finished turn cost, as far as the CLI would say.
///
/// Every field but ``ok`` is optional because the two CLIs report different things: Claude knows
/// a dollar cost, Codex knows tokens, and a turn that was interrupted knows neither.
public struct AgentTurnSummary: Codable, Equatable, Sendable {
    public let ok: Bool
    /// The turn was stopped by the user rather than finishing or failing.
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

/// One thing that happened in an agent session, in the one shape both CLI adapters produce and
/// the phone renders.
///
/// The index is monotonic per session and is the whole of the replay contract: the client applies
/// an event only if its index is greater than the last one it applied, which makes a replay that
/// races live output exact rather than a matter of luck. Indices start at 1, so `since: 0` means
/// "everything you still hold".
public struct AgentStreamEvent: Codable, Equatable, Sendable {
    public let index: UInt64
    public let payload: Payload

    public init(index: UInt64, payload: Payload) {
        self.index = index
        self.payload = payload
    }

    public enum Payload: Codable, Equatable, Sendable {
        /// The CLI is up. ``cliSessionID`` is the id to resume with after a restart; nil when the
        /// CLI does not have one yet or does not give one.
        case sessionReady(agentID: String, cliSessionID: String?, model: String?, directory: String)
        /// What the user said. Emitted by the host from the CLI's own echo where the CLI has one,
        /// so a replay rebuilds the whole conversation without a second source of truth.
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
        /// Worth a line in the transcript but not a failure: an unreadable line of CLI output, a
        /// truncation, an interruption.
        case notice(text: String)
        case failure(message: String)
        /// The CLI process ended. The session and its transcript stay readable.
        case sessionExited(status: Int32)
    }
}

/// Requests sent by an authenticated client for an agent chat session.
///
/// Sent only to a Mac that declared ``ServerHello/supportsAgentChat``: an older Mac cannot decode
/// this request and would fail the session rather than ignore it.
public enum AgentRequest: Codable, Equatable, Sendable {
    /// Every session this client owns, as summaries. Deliberately not their transcripts: see
    /// ``history(sessionID:since:)``, which the panel asks for the tabs it opens.
    case list
    /// Everything after ``since``, in as many ``AgentEvent/replay(sessionID:events:isLast:truncatedAtFront:)``
    /// chunks as it takes.
    case history(sessionID: UUID, since: UInt64)
    /// A new chat. ``directory`` is the folder the agent works in; nil means the Mac's home folder,
    /// the one path the phone cannot work out for itself.
    case start(agentID: String, directory: String?)
    /// What the user typed.
    case prompt(sessionID: UUID, text: String)
    /// The user's answer to one approval prompt. A second answer for the same id is ignored.
    case approval(sessionID: UUID, approvalID: String, decision: AgentApprovalDecision)
    /// Stop the turn in flight. The session stays; the next prompt starts a new turn.
    case interrupt(sessionID: UUID)
    /// What the session runs from now on. `nil` puts it back to the CLI's own default, which is
    /// the only thing the two agents agree on: Claude changes model inside the running process,
    /// Codex takes one per turn.
    ///
    /// Sent only to a Mac that declared ``ServerHello/supportsAgentModelPicker``.
    case setModel(sessionID: UUID, model: String?)
    /// End the session and the CLI with it.
    case close(sessionID: UUID)
    /// One folder's contents, for the picker a chat is started from. Needs no shell, unlike the
    /// terminal browser's ``TerminalRequest/listDirectory(sessionID:path:)``.
    case browse(path: String?)
}

/// Session state and stream events sent by the host.
public enum AgentEvent: Codable, Equatable, Sendable {
    case snapshot([AgentSessionInfo])
    case created(AgentSessionInfo)
    /// One live event.
    case stream(sessionID: UUID, event: AgentStreamEvent)
    /// A piece of the history ``AgentRequest/history(sessionID:since:)`` asked for.
    ///
    /// Chunked because this shares the control channel with every other message and a whole
    /// conversation is megabytes. ``truncatedAtFront`` says the Mac's own buffer no longer holds
    /// the start of the conversation, so the client can say so rather than show a transcript that
    /// quietly begins mid-turn.
    case replay(sessionID: UUID, events: [AgentStreamEvent], isLast: Bool, truncatedAtFront: Bool)
    /// A folder listing for the picker, in the browser's own entry type.
    case directory(path: String, entries: [RemoteDirectoryEntry], truncated: Bool)
    case browseFailure(path: String, message: String)
    case closed(sessionID: UUID)
    /// The model the session now runs, sent when the picker changes it and whenever the CLI
    /// itself announces one. `nil` is the CLI's default.
    case modelChanged(sessionID: UUID, model: String?)
    case failed(sessionID: UUID?, message: String)
}

/// Whether agent chat traffic may cross a session, in both directions.
///
/// The same two questions ``ClipboardImages`` asks, for the same reason: the message kinds behind
/// a chat are ones an older peer cannot decode, and an unreadable kind is a framing failure that
/// ends the session rather than a message it ignores. So each end reads the other's declaration
/// before sending, and only an explicit `true` counts: `nil` is a peer built before the field,
/// `false` is one that has said no.
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
