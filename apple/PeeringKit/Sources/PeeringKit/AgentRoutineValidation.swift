import Foundation
import RemoteCore

/// What makes a routine one the Mac refuses to keep.
public enum AgentRoutineProblem: Equatable, Sendable {
    case missingName
    case nameTooLong
    case missingPrompt
    case promptTooLong
    case relativeFolder
    case intervalOutOfRange
    case timeOutOfRange
    case noWeekdays
    case stopAfterOutOfRange
}

public enum AgentRoutineValidation {
    public static let nameLimit = 80
    public static let promptBytesLimit = 64 * 1024
    /// Shorter than this, a run would still be going when the next is due.
    public static let minimumIntervalMinutes = 15
    public static let maximumIntervalMinutes = 7 * 24 * 60
    public static let maximumStopAfterMinutes = 12 * 60

    /// The first problem found, or nil for a routine that can be kept.
    public static func problem(with routine: AgentRoutine) -> AgentRoutineProblem? {
        let name = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .missingName }
        if name.count > nameLimit { return .nameTooLong }
        if routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingPrompt }
        if routine.prompt.utf8.count > promptBytesLimit { return .promptTooLong }
        if !routine.directory.hasPrefix("/") { return .relativeFolder }
        if let problem = problem(with: routine.schedule) { return problem }
        if let limit = routine.stopAfterMinutes, !(1...maximumStopAfterMinutes).contains(limit) { return .stopAfterOutOfRange }
        return nil
    }

    private static func problem(with schedule: AgentRoutineSchedule) -> AgentRoutineProblem? {
        switch schedule {
        case .every(let minutes):
            return (minimumIntervalMinutes...maximumIntervalMinutes).contains(minutes) ? nil : .intervalOutOfRange
        case .daily(let hour, let minute, let weekdays):
            guard (0...23).contains(hour), (0...59).contains(minute) else { return .timeOutOfRange }
            let valid = weekdays.filter { (1...7).contains($0) }
            return valid.isEmpty || valid.count != weekdays.count ? .noWeekdays : nil
        }
    }

    /// The permission mode a new routine starts in: the most careful one the agent offers that can still finish without anyone there.
    public static func defaultMode(among modes: [AgentPermissionMode]) -> AgentPermissionMode {
        [.plan, .acceptEdits, .manual].first(where: modes.contains) ?? .manual
    }
}
