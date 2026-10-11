//! A client that drops and comes back asks for what it missed: the replay holds the events after its last index,
//! with the final text in place of the deltas that built it.

mod common;

use common::*;
use peering_wire::agent::{AgentEvent, AgentRequest, AgentStreamEvent, AgentStreamPayload};

#[test]
fn a_reconnecting_client_replays_only_the_events_after_the_last_one_it_saw() {
    let mut chat = start_chat();
    chat.manager.handle(AgentRequest::Prompt { session_id: chat.session_id.clone(), text: "ready?".to_owned() });
    chat.push_output(&fixture("text_turn.jsonl"));
    let live = Chat::stream_events(&chat.poll());
    let seen_up_to = live
        .iter()
        .find(|event| matches!(&event.payload, AgentStreamPayload::TextDelta { text } if text == "dy"))
        .expect("the last streamed delta was shown live")
        .index;

    let replay = chat.manager.handle(AgentRequest::History { session_id: chat.session_id.clone(), since: seen_up_to });

    let mut replayed: Vec<AgentStreamEvent> = Vec::new();
    let mut last_flags = Vec::new();
    for event in &replay {
        let AgentEvent::Replay { events, is_last, truncated_at_front, .. } = event else {
            panic!("expected a replay, got {event:?}");
        };
        assert!(!truncated_at_front);
        replayed.extend(events.iter().cloned());
        last_flags.push(*is_last);
    }
    // The final text replaces the deltas that built it, so the replay holds the tail only.
    assert!(matches!(
        replayed.as_slice(),
        [final_text, turn_end]
            if matches!(&final_text.payload, AgentStreamPayload::TextFinal { text } if text == "ready")
                && matches!(turn_end.payload, AgentStreamPayload::TurnFinished { .. })
                && final_text.index > seen_up_to
    ));
    assert_eq!(last_flags.last(), Some(&true));
}

#[test]
fn a_client_that_is_up_to_date_gets_an_empty_final_replay() {
    let mut chat = start_chat();
    chat.push_output(&fixture("text_turn.jsonl"));
    chat.poll();

    let replay = chat.manager.handle(AgentRequest::History { session_id: chat.session_id.clone(), since: u64::MAX - 1 });

    assert!(matches!(
        replay.as_slice(),
        [AgentEvent::Replay { events, is_last: true, .. }] if events.is_empty()
    ));
}
