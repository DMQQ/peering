use super::*;

fn releases(tags: &[&str]) -> String {
    let entries: Vec<String> = tags
        .iter()
        .map(|tag| format!(r#"{{"tag_name":"{tag}","html_url":"https://github.com/DMQQ/peering/releases/tag/{tag}"}}"#))
        .collect();
    format!("[{}]", entries.join(","))
}

#[test]
fn a_newer_release_is_a_notice_with_its_page() {
    let notice = judge("0.1.0", Ok(releases(&["windows-v0.2.0", "windows-v0.1.5"]))).expect("a good look").expect("a notice");
    assert_eq!(notice.version, "0.2.0");
    assert_eq!(notice.page, "https://github.com/DMQQ/peering/releases/tag/windows-v0.2.0");
}

#[test]
fn being_up_to_date_is_a_good_look_with_no_notice() {
    assert_eq!(judge("0.2.0", Ok(releases(&["windows-v0.2.0"]))), Ok(None));
    assert_eq!(judge("0.2.0", Ok(releases(&[]))), Ok(None));
}

#[test]
fn an_answer_that_could_not_be_had_or_read_is_a_failed_look() {
    assert!(judge("0.1.0", Err("no network".to_owned())).is_err());
    assert!(judge("0.1.0", Ok("<html>".to_owned())).is_err());
}

#[test]
fn a_host_that_does_not_look_never_succeeds_at_it() {
    assert!(NoReleases.fetch().is_err());
}
