import Foundation
import RemoteCore

/// A routine as its editor holds it: the schedule split into the fields the form shows.
public struct AgentRoutineDraft: Equatable, Sendable {
    public enum Cadence: String, CaseIterable, Sendable { case interval, daily }
    public enum IntervalUnit: String, CaseIterable, Sendable { case minutes, hours }

    public let id: UUID
    public var name: String
    public var agentID: String
    /// Nil until a folder is picked.
    public var directory: String?
    public var prompt: String
    public var cadence: Cadence
    public var intervalValue: Int
    public var intervalUnit: IntervalUnit
    public var hour: Int
    public var minute: Int
    public var weekdays: Set<Int>
    public var permissionMode: AgentPermissionMode
    public var isEnabled: Bool
    public var stopAfterMinutes: Int?
    public var notifiesWhenDone: Bool

    /// Weekday mornings at nine, in the agent's most careful mode that runs unattended.
    public init(agentID: String, modes: [AgentPermissionMode], id: UUID = UUID()) {
        self.id = id
        name = ""
        self.agentID = agentID
        directory = nil
        prompt = ""
        cadence = .daily
        intervalValue = 1
        intervalUnit = .hours
        hour = 9
        minute = 0
        weekdays = [2, 3, 4, 5, 6]
        permissionMode = AgentRoutineValidation.defaultMode(among: modes)
        isEnabled = true
        stopAfterMinutes = 30
        notifiesWhenDone = true
    }

    public init(_ routine: AgentRoutine) {
        self.init(agentID: routine.agentID, modes: [routine.permissionMode], id: routine.id)
        name = routine.name
        directory = routine.directory
        prompt = routine.prompt
        isEnabled = routine.isEnabled
        stopAfterMinutes = routine.stopAfterMinutes
        notifiesWhenDone = routine.notifiesWhenDone ?? true
        switch routine.schedule {
        case .every(let minutes):
            cadence = .interval
            let wholeHours = minutes % 60 == 0
            intervalUnit = wholeHours ? .hours : .minutes
            intervalValue = wholeHours ? minutes / 60 : minutes
        case .daily(let hour, let minute, let weekdays):
            cadence = .daily
            self.hour = hour
            self.minute = minute
            self.weekdays = Set(weekdays)
        }
    }

    public var schedule: AgentRoutineSchedule {
        switch cadence {
        case .interval: .every(minutes: intervalUnit == .hours ? intervalValue * 60 : intervalValue)
        case .daily: .daily(hour: hour, minute: minute, weekdays: weekdays.sorted())
        }
    }

    public var routine: AgentRoutine {
        AgentRoutine(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            agentID: agentID,
            directory: directory ?? "",
            prompt: prompt,
            schedule: schedule,
            permissionMode: permissionMode,
            isEnabled: isEnabled,
            stopAfterMinutes: stopAfterMinutes,
            notifiesWhenDone: notifiesWhenDone
        )
    }

    public var problem: AgentRoutineProblem? {
        AgentRoutineValidation.problem(with: routine)
    }
}
