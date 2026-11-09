//! When a routine runs next, and whether one is due now. Times are Unix seconds. Mirrors `AgentRoutinePlan.swift`.

use peering_wire::agent::AgentRoutineSchedule;

const DAY: i64 = 86_400;

/// The local time zone, asked per moment because the offset moves with daylight saving.
pub trait UtcOffset {
    fn seconds_east(&self, unix_seconds: i64) -> i64;
}

/// A zone that never changes.
pub struct FixedOffset(pub i64);

impl UtcOffset for FixedOffset {
    fn seconds_east(&self, _unix_seconds: i64) -> i64 {
        self.0
    }
}

/// The first time the schedule names strictly after `after`. `None` for a schedule that names no time at all.
pub fn next_fire(schedule: &AgentRoutineSchedule, after: i64, zone: &dyn UtcOffset) -> Option<i64> {
    match schedule {
        AgentRoutineSchedule::Every { minutes } => (*minutes > 0).then(|| after.saturating_add(minutes.saturating_mul(60))),
        AgentRoutineSchedule::Daily { hour, minute, weekdays } => {
            if !(0..=23).contains(hour) || !(0..=59).contains(minute) {
                return None;
            }
            let offset = zone.seconds_east(after);
            let today = (after + offset).div_euclid(DAY);
            // Eight days covers a week's worth of weekdays from either side of today's time.
            (0..=8).find_map(|ahead| {
                let day = today + ahead;
                if !weekdays.contains(&weekday_of(day)) {
                    return None;
                }
                let local = day * DAY + hour * 3600 + minute * 60;
                let fire = local - zone.seconds_east(local - offset);
                (fire > after).then_some(fire)
            })
        }
    }
}

/// Whether a run is owed. `since` is when the schedule was last satisfied: the last run, or when the routine was saved.
///
/// However many times were missed while the PC slept, this is one run: the next one is counted from when it starts.
pub fn is_due(schedule: &AgentRoutineSchedule, since: i64, now: i64, zone: &dyn UtcOffset) -> bool {
    next_fire(schedule, since, zone).is_some_and(|next| next <= now)
}

/// 1 is Sunday and 7 is Saturday, for a day counted from 1970-01-01, which was a Thursday.
fn weekday_of(day: i64) -> i64 {
    (day + 4).rem_euclid(7) + 1
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-10-13 is a Tuesday.
    const TUESDAY_NOON_UTC: i64 = 1_791_892_800;

    fn daily(hour: i64, minute: i64, weekdays: &[i64]) -> AgentRoutineSchedule {
        AgentRoutineSchedule::Daily { hour, minute, weekdays: weekdays.to_vec() }
    }

    #[test]
    fn weekdays_count_from_sunday() {
        assert_eq!(weekday_of(0), 5, "1970-01-01 was a Thursday");
        assert_eq!(weekday_of(TUESDAY_NOON_UTC / DAY), 3);
    }

    #[test]
    fn an_interval_is_counted_from_the_given_time() {
        let schedule = AgentRoutineSchedule::Every { minutes: 20 };
        assert_eq!(next_fire(&schedule, 1000, &FixedOffset(0)), Some(2200));
        assert_eq!(next_fire(&AgentRoutineSchedule::Every { minutes: 0 }, 1000, &FixedOffset(0)), None);
    }

    #[test]
    fn a_daily_time_later_today_fires_today() {
        let fire = next_fire(&daily(15, 30, &[3]), TUESDAY_NOON_UTC, &FixedOffset(0));
        assert_eq!(fire, Some(TUESDAY_NOON_UTC + 3 * 3600 + 1800));
    }

    #[test]
    fn a_daily_time_already_passed_waits_for_the_next_listed_weekday() {
        let fire = next_fire(&daily(9, 0, &[3, 5]), TUESDAY_NOON_UTC, &FixedOffset(0));
        assert_eq!(fire, Some(TUESDAY_NOON_UTC - 3 * 3600 + 2 * DAY), "Thursday at 09:00");
    }

    #[test]
    fn the_same_weekday_a_week_on_is_found() {
        let fire = next_fire(&daily(9, 0, &[3]), TUESDAY_NOON_UTC, &FixedOffset(0));
        assert_eq!(fire, Some(TUESDAY_NOON_UTC - 3 * 3600 + 7 * DAY));
    }

    #[test]
    fn local_time_is_read_through_the_zone() {
        let fire = next_fire(&daily(9, 0, &[3, 4]), TUESDAY_NOON_UTC, &FixedOffset(2 * 3600));
        assert_eq!(fire, Some(TUESDAY_NOON_UTC - 5 * 3600 + DAY), "09:00 at UTC+2 is 07:00 UTC, and today's has passed");
    }

    #[test]
    fn a_schedule_with_no_valid_time_or_weekday_never_fires() {
        assert_eq!(next_fire(&daily(24, 0, &[3]), 0, &FixedOffset(0)), None);
        assert_eq!(next_fire(&daily(9, 60, &[3]), 0, &FixedOffset(0)), None);
        assert_eq!(next_fire(&daily(9, 0, &[]), 0, &FixedOffset(0)), None);
        assert_eq!(next_fire(&daily(9, 0, &[8]), 0, &FixedOffset(0)), None);
    }

    #[test]
    fn many_missed_stretches_are_one_run() {
        let schedule = AgentRoutineSchedule::Every { minutes: 15 };
        assert!(is_due(&schedule, 0, 10 * 24 * 3600, &FixedOffset(0)));
        assert!(!is_due(&schedule, 10 * 24 * 3600, 10 * 24 * 3600 + 60, &FixedOffset(0)), "counted from the run that satisfied it");
    }

    #[test]
    fn a_zone_that_moves_changes_the_fire_time() {
        struct Springs;
        impl UtcOffset for Springs {
            fn seconds_east(&self, unix_seconds: i64) -> i64 {
                if unix_seconds >= TUESDAY_NOON_UTC + DAY / 2 { 3600 } else { 0 }
            }
        }
        let fire = next_fire(&daily(9, 0, &[4]), TUESDAY_NOON_UTC, &Springs);
        assert_eq!(fire, Some(TUESDAY_NOON_UTC - 3 * 3600 + DAY - 3600));
    }
}
