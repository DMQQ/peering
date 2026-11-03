import Foundation
import PeeringKit
import RemoteCore
import Testing

struct AgentRoutinePlanTests {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// 2026-11-02 is a Monday.
    private static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    @Test func anIntervalFiresThatLongAfterTheLastRun() {
        let next = AgentRoutinePlan.nextFire(of: .every(minutes: 90), after: Self.date(2, 10, 0), calendar: Self.utc)
        #expect(next == Self.date(2, 11, 30))
    }

    @Test func aDailyTimeLaterTodayFiresToday() {
        let next = AgentRoutinePlan.nextFire(of: .daily(hour: 18, minute: 30, weekdays: [2]), after: Self.date(2, 9, 0), calendar: Self.utc)
        #expect(next == Self.date(2, 18, 30))
    }

    @Test func aDailyTimeAlreadyPassedMovesToTheNextChosenWeekday() {
        let next = AgentRoutinePlan.nextFire(of: .daily(hour: 8, minute: 0, weekdays: [2, 4]), after: Self.date(2, 9, 0), calendar: Self.utc)
        #expect(next == Self.date(4, 8, 0))
    }

    @Test func aRoutineOnOneWeekdayWaitsAWholeWeek() {
        let next = AgentRoutinePlan.nextFire(of: .daily(hour: 8, minute: 0, weekdays: [2]), after: Self.date(2, 8, 0), calendar: Self.utc)
        #expect(next == Self.date(9, 8, 0))
    }

    @Test func noWeekdaysNamesNoTime() {
        let next = AgentRoutinePlan.nextFire(of: .daily(hour: 8, minute: 0, weekdays: []), after: Self.date(2, 8, 0), calendar: Self.utc)
        #expect(next == nil)
    }

    @Test func aRoutineIsNotDueBeforeItsTime() {
        #expect(!AgentRoutinePlan.isDue(.every(minutes: 60), since: Self.date(2, 10, 0), now: Self.date(2, 10, 59), calendar: Self.utc))
        #expect(AgentRoutinePlan.isDue(.every(minutes: 60), since: Self.date(2, 10, 0), now: Self.date(2, 11, 0), calendar: Self.utc))
    }

    @Test func aLongSleepOwesOneRunNotABurst() {
        let schedule = AgentRoutineSchedule.every(minutes: 60)
        let wake = Self.date(3, 9, 0)
        #expect(AgentRoutinePlan.isDue(schedule, since: Self.date(2, 9, 0), now: wake, calendar: Self.utc))
        // The catch-up run counts as the last one, so nothing else is owed at the same moment.
        #expect(!AgentRoutinePlan.isDue(schedule, since: wake, now: wake, calendar: Self.utc))
    }
}
