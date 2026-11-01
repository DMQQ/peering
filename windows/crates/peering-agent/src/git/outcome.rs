//! Turns what git printed into the one result the phone shows. Mirrors `AgentGitOutcome.swift`.

use peering_wire::agent::{AgentGitOperation, AgentGitResult};

use super::plan::GitRefusal;

pub const MAXIMUM_MESSAGE_LENGTH: usize = 1_200;
const NO_CREDENTIAL: &str = "This PC has no saved credential for this remote, and git cannot ask for one from here.";

pub fn result(operation: AgentGitOperation, succeeded: bool, output: &str) -> AgentGitResult {
    let text = output.trim();
    if succeeded {
        let fallback = if operation == AgentGitOperation::Commit { "Committed." } else { "Pushed." };
        let message = if text.is_empty() { fallback.to_owned() } else { head(text) };
        return AgentGitResult { operation, succeeded: true, message };
    }
    let mut message =
        if text.is_empty() { "git stopped without saying why. It may have run out of time.".to_owned() } else { tail(text) };
    if needs_credential(text) {
        message = format!("{NO_CREDENTIAL}\n\n{message}");
    }
    AgentGitResult { operation, succeeded: false, message }
}

pub fn refused(operation: AgentGitOperation, reason: &GitRefusal) -> AgentGitResult {
    failure(operation, &reason.text())
}

pub fn failure(operation: AgentGitOperation, message: &str) -> AgentGitResult {
    AgentGitResult { operation, succeeded: false, message: message.to_owned() }
}

/// The end of the output, where git states its error after a hook has printed its chatter.
fn tail(text: &str) -> String {
    let count = text.chars().count();
    if count <= MAXIMUM_MESSAGE_LENGTH {
        return text.to_owned();
    }
    format!("\u{2026}{}", text.chars().skip(count - MAXIMUM_MESSAGE_LENGTH).collect::<String>())
}

fn head(text: &str) -> String {
    if text.chars().count() <= MAXIMUM_MESSAGE_LENGTH {
        return text.to_owned();
    }
    format!("{}\u{2026}", text.chars().take(MAXIMUM_MESSAGE_LENGTH).collect::<String>())
}

fn needs_credential(text: &str) -> bool {
    let lowered = text.to_lowercase();
    [
        "could not read username",
        "could not read password",
        "authentication failed",
        "permission denied (publickey",
        "terminal prompts disabled",
    ]
    .iter()
    .any(|sign| lowered.contains(sign))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_quiet_success_says_what_was_done() {
        assert_eq!(result(AgentGitOperation::Commit, true, " \n").message, "Committed.");
        assert_eq!(result(AgentGitOperation::Push, true, "").message, "Pushed.");
    }

    #[test]
    fn a_long_failure_keeps_its_end() {
        let output = format!("{}the error", "x".repeat(2_000));
        let message = result(AgentGitOperation::Push, false, &output).message;
        assert!(message.starts_with('\u{2026}') && message.ends_with("the error"));
        assert_eq!(message.chars().count(), MAXIMUM_MESSAGE_LENGTH + 1);
    }

    #[test]
    fn a_missing_credential_is_explained_before_gits_words() {
        let message = result(AgentGitOperation::Push, false, "fatal: Authentication failed for x").message;
        assert!(message.starts_with(NO_CREDENTIAL));
        assert!(message.ends_with("fatal: Authentication failed for x"));
    }

    #[test]
    fn a_silent_failure_suggests_a_timeout() {
        assert!(!result(AgentGitOperation::Commit, false, "").succeeded);
    }
}
