//! The transcript a chat keeps: its indices, what replay sends, and what the size limit drops.

use super::transcript::TranscriptLog;
use peering_wire::agent::{AgentEvent, AgentStreamPayload};

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
    let big = "x".repeat(14_000);
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
    let long = "x".repeat(40_000);
    for _ in 0..8 {
        log.append(prompt(&long));
        log.append(AgentStreamPayload::TextFinal { text: long.clone() });
    }

    assert!(log.truncated_at_front());
    assert!(log.chunks(0)[0][0].index > 1);
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

fn largest_replay_frame(log: &TranscriptLog) -> usize {
    log.chunks(0)
        .into_iter()
        .map(|events| {
            let replay = AgentEvent::Replay { session_id: "0".repeat(36), events, is_last: false, truncated_at_front: false };
            serde_json::to_vec(&replay).expect("a replay serialises").len()
        })
        .max()
        .expect("the log holds events")
}

#[test]
fn the_largest_encoded_replay_frame_stays_under_the_64_kib_rule() {
    let mut log = TranscriptLog::new();
    let escaped = "\"\n\t\\".repeat(2_000);
    for _ in 0..40 {
        log.append(AgentStreamPayload::TextFinal { text: escaped.clone() });
        log.append(notice(&"x".repeat(30_000)));
    }
    assert!(largest_replay_frame(&log) < 64 * 1024);
}

#[test]
fn one_reply_too_long_for_a_frame_is_cut_with_a_marker() {
    let mut log = TranscriptLog::new();
    let event = log.append(AgentStreamPayload::TextFinal { text: "\u{e9}\n".repeat(100_000) });
    let AgentStreamPayload::TextFinal { text } = &event.payload else { panic!("a final reply stays a final reply") };
    assert!(text.ends_with("too long to send]"));
    assert!(largest_replay_frame(&log) < 64 * 1024);
}
