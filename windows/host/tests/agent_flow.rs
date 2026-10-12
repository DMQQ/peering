mod support;

use peering_wire::agent::{AgentEvent, AgentRequest};
use peering_wire::framing::MessageKind;
use support::*;

async fn ask(phone: &mut Phone, request: &AgentRequest) {
    phone.send_json(MessageKind::AgentRequest, request).await;
}

async fn next_event(phone: &mut Phone) -> AgentEvent {
    decode_json(&phone.next_of(MessageKind::AgentEvent).await)
}

#[test]
fn a_chat_survives_its_phone_reconnecting() {
    run(async {
        let harness = harness();
        let mut first = paired_phone(&harness.runtime).await;
        ask(&mut first, &AgentRequest::Start { agent_id: "claude".to_owned(), directory: Some("/C:/Users".to_owned()) }).await;
        let AgentEvent::Created { session } = next_event(&mut first).await else { panic!("a created chat") };
        drop(first);

        let mut second = reconnected_phone(&harness.runtime).await;
        ask(&mut second, &AgentRequest::List {}).await;
        let AgentEvent::Snapshot { sessions } = next_event(&mut second).await else { panic!("a snapshot") };
        assert_eq!(sessions.iter().map(|chat| chat.id.as_str()).collect::<Vec<_>>(), [session.id.as_str()]);
    });
}

#[test]
fn browsing_a_folder_that_is_not_there_answers_with_a_failure() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        ask(&mut phone, &AgentRequest::Browse { path: Some("/Z:/missing".to_owned()) }).await;
        assert!(matches!(next_event(&mut phone).await, AgentEvent::BrowseFailure { .. }));
    });
}

#[test]
fn browsing_a_reserved_device_name_is_refused() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        ask(&mut phone, &AgentRequest::Browse { path: Some("/C:/nul".to_owned()) }).await;
        assert!(matches!(next_event(&mut phone).await, AgentEvent::BrowseFailure { .. }));
    });
}
