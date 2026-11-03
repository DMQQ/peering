import Foundation
import RemoteCore

/// When a routine runs next, and whether one is due now.
public enum AgentRoutinePlan {
    /// The first time the schedule names strictly after `date`. Nil for a schedule that names no time at all.
    public static func nextFire(of schedule: AgentRoutineSchedule, after date: Date, calendar: Calendar = .current) -> Date? {
        switch schedule {
        case .every(let minutes):
            guard minutes > 0 else { return nil }
            return date.addingTimeInterval(TimeInterval(minutes * 60))
        case .daily(let hour, let minute, let weekdays):
            let days = Set(weekdays)
            // Eight days covers a week's worth of weekdays from either side of today's time.
            for offset in 0...8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
                      days.contains(calendar.component(.weekday, from: day)),
                      let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                      fire > date
                else { continue }
                return fire
            }
            return nil
        }
    }

    /// Whether a run is owed. `since` is when the schedule was last satisfied: the last run, or when the routine was saved.
    ///
    /// However many times were missed while the Mac slept, this is one run: the next one is counted from when it starts.
    public static func isDue(_ schedule: AgentRoutineSchedule, since: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let next = nextFire(of: schedule, after: since, calendar: calendar) else { return false }
        return next <= now
    }
}
