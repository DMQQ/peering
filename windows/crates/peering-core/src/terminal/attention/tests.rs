use super::*;

fn detector() -> AttentionDetector {
    AttentionDetector::default()
}

#[test]
fn claude_permission_choices_ask_for_attention() {
    let prompt = "Do you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again\n  3. No\nEsc to cancel";
    assert_eq!(detector().receive(prompt.as_bytes()), Some(TerminalAttentionKind::Confirmation));
}

#[test]
fn claude_multiple_choice_questions_ask_for_attention() {
    let prompt = "Which deployment should I use?\n❯ 1. Staging\n  2. Production\n  3. Let me type another answer";
    assert_eq!(detector().receive(prompt.as_bytes()), Some(TerminalAttentionKind::Confirmation));
}

#[test]
fn a_prompt_split_between_reads_is_detected_only_when_complete() {
    let mut detector = detector();
    assert_eq!(detector.receive(b"Do you want to pro"), None);
    let rest = "ceed?\r\n\u{1B}[36m❯ 1. Yes\u{1B}[0m\r\n  2. No";
    assert_eq!(detector.receive(rest.as_bytes()), Some(TerminalAttentionKind::Confirmation));
}

#[test]
fn a_redrawn_prompt_notifies_once_until_the_user_responds() {
    let mut detector = detector();
    let prompt = "Allow this tool?\r\n❯ 1. Yes\r\n  2. No".as_bytes();
    assert_eq!(detector.receive(prompt), Some(TerminalAttentionKind::Confirmation));
    assert_eq!(detector.receive(prompt), None);
    detector.user_did_respond();
    assert_eq!(detector.receive(prompt), Some(TerminalAttentionKind::Confirmation));
}

#[test]
fn password_and_conventional_confirmation_prompts_ask_for_attention() {
    assert_eq!(detector().receive(b"Password for deploy@example.com: "), Some(TerminalAttentionKind::Password));
    assert_eq!(detector().receive(b"Continue? [y/N] "), Some(TerminalAttentionKind::Confirmation));
    assert_eq!(detector().receive(b"Are you sure you want to delete it? "), Some(TerminalAttentionKind::Confirmation));
    assert_eq!(detector().receive(b"Press Enter to continue\r\n"), Some(TerminalAttentionKind::Confirmation));
}

#[test]
fn the_prompt_that_asked_is_what_the_notification_quotes() {
    let mut sudo = detector();
    assert_eq!(sudo.receive(b"$ ls\r\n[sudo] password for damian: "), Some(TerminalAttentionKind::Password));
    assert_eq!(sudo.question().as_deref(), Some("[sudo] password for damian:"));

    let mut coloured = detector();
    let prompt = "deploy@example.com's password:\u{1B}[0m ";
    assert_eq!(coloured.receive(prompt.as_bytes()), Some(TerminalAttentionKind::Password));
    assert_eq!(coloured.question().as_deref(), Some("deploy@example.com's password:"));
}

#[test]
fn a_claude_chooser_is_quoted_by_its_question_not_its_footer() {
    let mut detector = detector();
    let prompt = "Do you want to make this edit to Theme.swift?\n❯ 1. Yes\n  2. Yes, allow all edits\n  3. No\nEsc to cancel · Tab to amend";
    assert_eq!(detector.receive(prompt.as_bytes()), Some(TerminalAttentionKind::Confirmation));
    assert_eq!(detector.question().as_deref(), Some("Do you want to make this edit to Theme.swift?"));
}

#[test]
fn a_question_that_cannot_be_read_is_not_guessed_at() {
    let mut repainting = detector();
    repainting.receive(format!("{}\n", "x".repeat(200)).as_bytes());
    assert_eq!(repainting.question(), None);

    let mut animated = detector();
    animated.receive(b"Password: \x07");
    assert_eq!(animated.question(), None);
}

#[test]
fn ordinary_questions_and_numbered_output_do_not_ask_for_attention() {
    assert_eq!(detector().receive(b"What changed in this release?\r\n"), None);
    assert_eq!(detector().receive(b"1. Build\r\n2. Test\r\n3. Ship\r\n"), None);
}

#[test]
fn a_tail_cut_inside_a_character_does_not_panic() {
    let mut detector = detector();
    detector.receive("é".repeat(4_000).as_bytes());
    assert_eq!(detector.receive(b"ok"), None);
}
