import Foundation
import PeeringKit
import RemoteCore

/// How a routine's schedule and last run read on the phone.
enum AgentRoutineText {
    static func schedule(_ schedule: AgentRoutineSchedule) -> String {
        switch schedule {
        case .every(let minutes):
            let duration = minutes % 60 == 0
                ? Measurement(value: Double(minutes / 60), unit: UnitDuration.hours)
                : Measurement(value: Double(minutes), unit: UnitDuration.minutes)
            return String(localized: "Every \(duration.formatted(.measurement(width: .wide)))")
        case .daily(let hour, let minute, let weekdays):
            let time = clock(hour: hour, minute: minute)
            if weekdays.count == 7 { return String(localized: "Every day at \(time)") }
            if Set(weekdays) == [2, 3, 4, 5, 6] { return String(localized: "Weekdays at \(time)") }
            let symbols = Calendar.current.shortWeekdaySymbols
            let days = weekdays.sorted().compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
            return String(localized: "\(days.formatted(.list(type: .and))) at \(time)")
        }
    }

    static func clock(hour: Int, minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func lastRun(_ run: AgentRoutineRun?) -> String {
        guard let run else { return String(localized: "Has not run yet") }
        let when = run.startedAt.formatted(.relative(presentation: .named))
        let line = switch run.outcome {
        case .running: String(localized: "Running, started \(when)")
        case .succeeded: String(localized: "Finished \(when)")
        case .failed: String(localized: "Failed \(when)")
        case .stopped: String(localized: "Stopped \(when)")
        case .skipped: String(localized: "Skipped \(when)")
        }
        guard let detail = run.detail else { return line }
        return "\(line). \(detail)"
    }

    static func nextRun(_ routine: AgentRoutine) -> String? {
        guard routine.isEnabled else { return String(localized: "Off") }
        guard let next = routine.nextRunAt else { return nil }
        return String(localized: "Next \(next.formatted(.relative(presentation: .named)))")
    }

    static func problem(_ problem: AgentRoutineProblem) -> String {
        switch problem {
        case .missingName: String(localized: "Give the routine a name.")
        case .nameTooLong: String(localized: "That name is too long.")
        case .missingPrompt: String(localized: "Write what the agent should do.")
        case .promptTooLong: String(localized: "That prompt is too long to send.")
        case .relativeFolder: String(localized: "Choose the folder the agent works in.")
        case .intervalOutOfRange: String(localized: "Runs can be from 15 minutes to 7 days apart.")
        case .timeOutOfRange: String(localized: "Choose a time of day.")
        case .noWeekdays: String(localized: "Choose at least one day.")
        case .stopAfterOutOfRange: String(localized: "The time limit can be up to 12 hours.")
        }
    }
}
