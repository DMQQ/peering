use super::*;

fn release(tag: &str) -> String {
    format!(r#"{{"tag_name":"{tag}","html_url":"{RELEASE_PAGE_PREFIX}tag/{tag}","draft":false,"prerelease":false}}"#)
}

fn list(entries: &[String]) -> String {
    format!("[{}]", entries.join(","))
}

#[test]
fn versions_are_read_with_or_without_the_tag_prefix() {
    assert_eq!(Version::parse("windows-v1.2.3"), Some(Version { major: 1, minor: 2, patch: 3 }));
    assert_eq!(Version::parse("v0.4"), Some(Version { major: 0, minor: 4, patch: 0 }));
    assert_eq!(Version::parse("7"), Some(Version { major: 7, minor: 0, patch: 0 }));
}

#[test]
fn what_is_not_a_plain_version_is_not_one() {
    for text in ["", "windows-v", "1.2.3.4", "1.x", "1.2.3-rc1", "1..2", "-1.0", "latest", "1.2.3 "] {
        assert_eq!(Version::parse(text), None, "{text:?}");
    }
}

#[test]
fn versions_compare_by_number_not_by_text() {
    assert!(Version::parse("1.10.0") > Version::parse("1.9.9"));
    assert!(Version::parse("2.0.0") > Version::parse("1.99.99"));
}

#[test]
fn the_newest_windows_release_is_chosen_whatever_the_order_of_the_list() {
    let json = list(&[release("windows-v0.2.0"), release("windows-v0.10.0"), release("windows-v0.9.5")]);
    let newest = newest_release(&json).expect("a readable list").expect("a release");
    assert_eq!(newest.version.to_string(), "0.10.0");
    assert_eq!(newest.page, format!("{RELEASE_PAGE_PREFIX}tag/windows-v0.10.0"));
}

#[test]
fn releases_of_other_programs_drafts_and_pre_releases_are_ignored() {
    let draft = format!(r#"{{"tag_name":"windows-v9.0.0","html_url":"{RELEASE_PAGE_PREFIX}tag/windows-v9.0.0","draft":true}}"#);
    let pre = format!(r#"{{"tag_name":"windows-v8.0.0","html_url":"{RELEASE_PAGE_PREFIX}tag/windows-v8.0.0","prerelease":true}}"#);
    let json = list(&[release("android-v5.0.0"), release("v6.0.0"), draft, pre, release("windows-v0.2.0")]);
    let newest = newest_release(&json).expect("a readable list").expect("a release");
    assert_eq!(newest.version.to_string(), "0.2.0");
}

#[test]
fn a_release_page_on_another_site_is_never_shown() {
    let elsewhere = r#"{"tag_name":"windows-v9.0.0","html_url":"https://example.com/download"}"#.to_owned();
    assert_eq!(newest_release(&list(&[elsewhere])), Ok(None));
}

#[test]
fn a_list_with_no_windows_release_has_no_newest() {
    assert_eq!(newest_release("[]"), Ok(None));
    assert_eq!(newest_release(&list(&[release("android-v1.0.0")])), Ok(None));
}

#[test]
fn an_answer_that_is_not_a_list_is_an_error_and_not_a_missing_release() {
    assert!(newest_release(r#"{"message":"API rate limit exceeded"}"#).is_err());
    assert!(newest_release("not json").is_err());
}

#[test]
fn a_newer_release_gives_a_notice_and_the_same_or_an_older_one_does_not() {
    let newest = newest_release(&list(&[release("windows-v0.2.0")])).unwrap().unwrap();
    let notice = notice_for("0.1.0", &newest).expect("a notice");
    assert_eq!(notice.version, "0.2.0");
    assert_eq!(notice.page, newest.page);
    assert_eq!(notice_for("0.2.0", &newest), None);
    assert_eq!(notice_for("0.3.0", &newest), None);
}

#[test]
fn a_running_version_that_cannot_be_read_is_told_nothing() {
    let newest = newest_release(&list(&[release("windows-v0.2.0")])).unwrap().unwrap();
    assert_eq!(notice_for("unknown", &newest), None);
}

#[test]
fn the_first_look_waits_a_minute_and_then_a_day_after_success_or_an_hour_after_failure() {
    let mut schedule = CheckSchedule::starting_at(100.0);
    assert!(!schedule.due(159.0));
    assert!(schedule.due(160.0));
    schedule.looked(200.0, true);
    assert!(!schedule.due(200.0 + 24.0 * 3600.0 - 1.0));
    assert!(schedule.due(200.0 + 24.0 * 3600.0));
    schedule.looked(500.0, false);
    assert!(!schedule.due(500.0 + 3599.0));
    assert!(schedule.due(500.0 + 3600.0));
}
