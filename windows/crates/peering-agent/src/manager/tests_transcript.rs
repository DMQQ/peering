//! The transcript a chat keeps: its indices, what replay sends, and what the size limit drops.

use super::transcript::TranscriptLog;
use peering_wire::agent::AgentStreamPayload;

fn notice(text: &str) -> AgentStreamPayload {
    AgentStreamPayload::Notice { text: text.to_owned() }
}

fn prompt(text: &str) -> AgentStreamPayload {
    AgentStreamPayload::UserPrompt { text: text.to_owned() }
}

fn indexes(chunks: &[Vec<peering_wire::agent::AgentStreamEvent>]) -> Vec<Vec<u64>> {
    chunks
        .iter()
        .map(|chunk| chunk.iter().map(|event| event.index).collect())
        .collect()
}

#[test]
fn indices_start_at_one_and_follow_each_append() {
    let mut log = TranscriptLog::new();
    assert_eq!(log.last_index(), 0);
    assert_eq!(log.append(notice("a")).index, 1);
    assert_eq!(log.append(notice("b")).index, 2);
    assert_eq!(log.last_index(), 2);
}

#[test]
fn a_final_reply_replaces_the_deltas_before_it() {
    let mut log = TranscriptLog::new();
    log.append(AgentStreamPayload::TextDelta { text: "ab".to_owned() });
    log.append(AgentStreamPayload::TextDelta { text: "c".to_owned() });
    log.append(AgentStreamPayload::TextFinal { text: "abc".to_owned() });
    assert_eq!(indexes(&log.chunks(0)), [[3]]);
    assert_eq!(log.last_index(), 3);
}

#[test]
fn replay_is_split_at_the_event_budget() {
    let mut log = TranscriptLog::new();
    for _ in 0..450 {
        log.append(notice("n"));
    }
    let sizes: Vec<usize> = log.chunks(0).iter().map(Vec::len).collect();
    assert_eq!(sizes, [200, 200, 50]);
}

#[test]
fn replay_is_split_at_the_byte_budget() {
    let mut log = TranscriptLog::new();
    let big = "x".repeat(30_000);
    for _ in 0..3 {
        log.append(notice(&big));
    }
    let sizes: Vec<usize> = log.chunks(0).iter().map(Vec::len).collect();
    assert_eq!(sizes, [2, 1]);
}

#[test]
fn replay_starts_after_the_given_index() {
    let mut log = TranscriptLog::new();
    for text in ["a", "b", "c", "d", "e"] {
        log.append(notice(text));
    }
    assert_eq!(indexes(&log.chunks(3)), [[4, 5]]);
    assert!(log.chunks(5).is_empty());
}

#[test]
fn a_long_transcript_drops_its_oldest_whole_turns_and_says_so() {
    let mut log = TranscriptLog::new();
    let long = "x".repeat(200_000);
    log.append(prompt(&long));
    log.append(AgentStreamPayload::TextFinal { text: long.clone() });
    log.append(prompt(&long));

    assert!(log.truncated_at_front());
    assert_eq!(indexes(&log.chunks(0)), [[3]]);
    assert!(log.has_prompt());
}

#[test]
fn a_single_long_turn_keeps_its_shape_and_loses_its_oldest_tool_output() {
    let mut log = TranscriptLog::new();
    log.append(prompt("go"));
    let output = "y".repeat(32 * 1024);
    for id in 0..20 {
        log.append(AgentStreamPayload::ToolFinished {
            call_id: format!("call-{id}"),
            ok: true,
            output: Some(output.clone()),
            truncated: false,
        });
    }
    assert!(!log.truncated_at_front());
    let finished: Vec<(bool, bool)> = log
        .chunks(0)
        .concat()
        .iter()
        .filter_map(|event| match &event.payload {
            AgentStreamPayload::ToolFinished { output, truncated, .. } => Some((output.is_some(), *truncated)),
            _ => None,
        })
        .collect();
    assert_eq!(finished.len(), 20);
    assert!(finished[..5].iter().all(|(has_output, truncated)| !has_output && *truncated));
    assert!(finished[5..].iter().all(|(has_output, truncated)| *has_output && !*truncated));
}
