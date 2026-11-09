import Foundation

/// A prompt the Mac sends to an agent on a schedule, in a chat of its own, while the phone is away.
///
/// Exchanged only with a Mac that declared ``ServerHello/supportsAgentRoutines``.
public struct AgentRoutine: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// A catalogue id the Mac listed in ``ServerHello/agentChatAgents``.
    public var agentID: String
    /// An absolute path on the Mac.
    public var directory: String
    public var prompt: String
    public var schedule: AgentRoutineSchedule
    public var permissionMode: AgentPermissionMode
    public var isEnabled: Bool
    /// Whether the phone is told when a run ends, wherever the phone is. Nil means yes, which is what a routine saved before this field existed did not say.
    public var notifiesWhenDone: Bool?
    /// The Mac stops the run once it has gone on this long. Nil lets it finish.
    public var stopAfterMinutes: Int?
    /// Kept by the Mac: whatever the phone sends here is ignored.
    public var lastRun: AgentRoutineRun?
    /// Kept by the Mac, as ``lastRun`` is.
    public var nextRunAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        agentID: String,
        directory: String,
        prompt: String,
        schedule: AgentRoutineSchedule,
        permissionMode: AgentPermissionMode,
        notifiesWhenDone: Bool? = nil,
        isEnabled: Bool = true,
        stopAfterMinutes: Int? = nil,
        lastRun: AgentRoutineRun? = nil,
        nextRunAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.agentID = agentID
        self.directory = directory
        self.prompt = prompt
        self.schedule = schedule
        self.permissionMode = permissionMode
        self.notifiesWhenDone = notifiesWhenDone
        self.isEnabled = isEnabled
        self.stopAfterMinutes = stopAfterMinutes
        self.lastRun = lastRun
        self.nextRunAt = nextRunAt
    }
}

/// When a routine runs. Weekdays are numbered as `Calendar` numbers them: 1 is Sunday, 7 is Saturday.
public enum AgentRoutineSchedule: Codable, Equatable, Sendable {
    case every(minutes: Int)
    case daily(hour: Int, minute: Int, weekdays: [Int])
}

/// One run of a routine, as the Mac last recorded it.
public struct AgentRoutineRun: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case running
        case succeeded
        case failed
        /// Ended by the routine's own time limit.
        case stopped
        /// Never started; ``AgentRoutineRun/detail`` says why.
        case skipped
    }

    public var startedAt: Date
    public var outcome: Outcome
    public var detail: String?
    /// The chat the run happened in. Nil for a run that was skipped.
    public var sessionID: UUID?

    public init(startedAt: Date, outcome: Outcome, detail: String? = nil, sessionID: UUID? = nil) {
        self.startedAt = startedAt
        self.outcome = outcome
        self.detail = detail
        self.sessionID = sessionID
    }
}
