//! Dates from seconds since the Unix epoch, without a time zone database: the log and the zip format both want UTC.

/// Days since 1970-01-01 as a calendar date (Howard Hinnant's algorithm).
pub fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * month_index + 2) / 5 + 1) as u32;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 } as u32;
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// `2026-10-13T12:00:00Z`.
pub fn iso_utc(unix_seconds: i64) -> String {
    let (year, month, day) = civil_from_days(unix_seconds.div_euclid(86_400));
    let seconds = unix_seconds.rem_euclid(86_400);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", seconds / 3600, seconds % 3600 / 60, seconds % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_epoch_is_the_first_of_january_1970() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(iso_utc(0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn a_known_moment_is_written_in_full() {
        assert_eq!(iso_utc(1_614_834_368), "2021-03-04T05:06:08Z");
        assert_eq!(iso_utc(1_791_892_800), "2026-10-13T12:00:00Z");
    }

    #[test]
    fn leap_days_and_century_years_are_right() {
        assert_eq!(civil_from_days(11_016), (2000, 2, 29));
        assert_eq!(iso_utc(951_868_800), "2000-03-01T00:00:00Z");
        assert_eq!(iso_utc(4_107_542_400), "2100-03-01T00:00:00Z");
    }

    #[test]
    fn a_moment_before_the_epoch_is_still_a_date() {
        assert_eq!(iso_utc(-1), "1969-12-31T23:59:59Z");
    }
}
