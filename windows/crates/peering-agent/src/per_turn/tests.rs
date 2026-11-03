use super::{PerTurnAdapter, TurnCli};
use crate::claude_adapter::fake::{lock, push_lines, shared_script, ScriptedLauncher};
use crate::codex_stream::CodexStream;
use crate::opencode_stream::OpenCodeStream;
use peering_wire::agent::{AgentPermissionMode, AgentStreamPayload};
use std::path::PathBuf;

fn codex(thread: Option<&str>) -> PerTurnAdapter {
    let cli = TurnCli::Codex { stream: CodexStream::new("/work", thread.map(str::to_owned)), sessions: None, log_path: Default::default() };
    PerTurnAdapter::new(PathBuf::from("/work"), cli, None, None)
}

#[test]
fn a_first_codex_turn_names_the_sandbox_and_folder() {
    let script = shared_script();
    let mut launcher = ScriptedLauncher::new(&script);
    let mut adapter = codex(None);
    adapter.start();
    assert!(adapter.prompt("hello", &mut launcher));
    let launch = lock(&script).launches[0].clone();
    assert_eq!(launch.program, "codex");
    assert_eq!(
        launch.arguments,
        ["exec", "--json", "--sandbox", "workspace-write", "--skip-git-repo-check", "--cd", "/work", "--", "-"]
    );
    assert_eq!(launch.input.as_deref(), Some("hello"));
}

#[test]
fn a_codex_resume_sets_model_and_sandbox_through_config() {
    let script = shared_script();
    let mut launcher = ScriptedLauncher::new(&script);
    let mut adapter = codex(Some("t-1"));
    adapter.set_model(Some("gpt-5"));
    adapter.set_permission_mode(AgentPermissionMode::Auto);
    adapter.prompt("go", &mut launcher);
    assert_eq!(
        lock(&script).launches[0].arguments,
        ["-c", "model=gpt-5", "-c", "sandbox_mode=danger-full-access", "exec", "resume", "--skip-git-repo-check", "--json", "--", "t-1", "-"]
    );
}

#[test]
fn opencode_passes_auto_model_and_session_and_the_text_on_stdin() {
    let script = shared_script();
    let mut launcher = ScriptedLauncher::new(&script);
    let cli = TurnCli::OpenCode(OpenCodeStream::new("/work", Some("ses".to_owned())));
    let mut adapter = PerTurnAdapter::new(PathBuf::from("/work"), cli, Some("a/b".to_owned()), Some(AgentPermissionMode::Auto));
    adapter.prompt("-x", &mut launcher);
    assert_eq!(
        lock(&script).launches[0].arguments,
        ["run", "--format", "json", "--auto", "-m", "a/b", "-s", "ses"]
    );
    assert_eq!(lock(&script).launches[0].input.as_deref(), Some("-x"));
}

#[test]
fn no_prompt_text_reaches_the_command_line() {
    let hostile = "-x\" & calc & \"%PATH%\nrest";
    for thread in [None, Some("t-1")] {
        let script = shared_script();
        let mut launcher = ScriptedLauncher::new(&script);
        let mut adapter = codex(thread);
        adapter.prompt(hostile, &mut launcher);
        let launch = lock(&script).launches[0].clone();
        assert!(launch.arguments.iter().all(|argument| !argument.contains("calc")), "{:?}", launch.arguments);
        assert_eq!(launch.input.as_deref(), Some(hostile));
    }
}

#[test]
fn modes_without_a_sandbox_meaning_are_refused() {
    let mut adapter = codex(None);
    assert!(!adapter.set_permission_mode(AgentPermissionMode::Manual));
    assert_eq!(adapter.permission_mode(), AgentPermissionMode::AcceptEdits);
}

#[test]
fn a_process_that_ends_mid_turn_finishes_it_with_a_notice_and_reports_usage() {
    let script = shared_script();
    let mut launcher = ScriptedLauncher::new(&script);
    let mut adapter = codex(None);
    adapter.prompt("hi", &mut launcher);
    {
        let mut script = lock(&script);
        script.closed = true;
        script.exit_status = 3;
    }
    let payloads = adapter.poll(&mut launcher);
    assert!(matches!(&payloads[0], AgentStreamPayload::Notice { text } if text.contains("status 3")));
    assert!(matches!(&payloads[1], AgentStreamPayload::TurnFinished { summary } if !summary.ok && !summary.stopped));
    assert!(adapter.take_usage_due());
    assert!(!adapter.take_usage_due());
}

#[test]
fn an_interrupted_turn_is_reported_stopped() {
    let script = shared_script();
    let mut launcher = ScriptedLauncher::new(&script);
    let mut adapter = codex(None);
    adapter.prompt("hi", &mut launcher);
    assert!(adapter.interrupt());
    let payloads = adapter.poll(&mut launcher);
    assert!(matches!(payloads.as_slice(), [AgentStreamPayload::TurnFinished { summary }] if summary.stopped));
}

#[test]
fn a_prompt_during_a_turn_waits_for_it_and_then_runs() {
    let script = shared_script();
    let mut launcher = ScriptedLauncher::new(&script);
    let mut adapter = codex(None);
    adapter.start();
    adapter.prompt("one", &mut launcher);
    adapter.prompt("two", &mut launcher);
    assert_eq!(lock(&script).launches.len(), 1);
    push_lines(&script, &[r#"{"type":"turn.completed","usage":{}}"#]);
    lock(&script).closed = true;
    let payloads = adapter.poll(&mut launcher);
    assert!(matches!(payloads.as_slice(), [AgentStreamPayload::TurnFinished { summary }] if summary.ok));
    assert_eq!(lock(&script).launches.len(), 2);
}
