//! Which agent events a client may be sent. An event whose enum case an older phone cannot decode ends its session, so the
//! host sends one only when the client declared it in its hello.

use peering_wire::agent::AgentEvent;
use peering_wire::handshake::ClientCapabilities;

pub(super) fn admits(event: &AgentEvent, client: &ClientCapabilities) -> bool {
    if client.supports_agent_chat != Some(true) {
        return false;
    }
    match event {
        AgentEvent::PermissionModeChanged { .. } => client.supports_agent_permission_modes == Some(true),
        AgentEvent::UsageChanged { .. } => client.supports_agent_usage == Some(true),
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use peering_wire::agent::{AgentPermissionMode, AgentUsage};

    fn chat_client() -> ClientCapabilities {
        ClientCapabilities { supports_agent_chat: Some(true), ..ClientCapabilities::default() }
    }

    fn mode_event() -> AgentEvent {
        AgentEvent::PermissionModeChanged { session_id: "s".to_owned(), mode: AgentPermissionMode::Plan }
    }

    fn usage_event() -> AgentEvent {
        let usage = AgentUsage {
            context_used_tokens: None,
            context_window_tokens: None,
            input_tokens: 0,
            cached_tokens: 0,
            output_tokens: 0,
            cost_usd: None,
            limits: Vec::new(),
        };
        AgentEvent::UsageChanged { session_id: "s".to_owned(), usage }
    }

    fn closed() -> AgentEvent {
        AgentEvent::Closed { session_id: "s".to_owned() }
    }

    #[test]
    fn a_client_that_did_not_declare_agent_chat_gets_no_agent_event() {
        assert!(!admits(&closed(), &ClientCapabilities::default()));
    }

    #[test]
    fn permission_mode_changes_wait_for_the_permission_modes_flag() {
        assert!(!admits(&mode_event(), &chat_client()));
        let declared = ClientCapabilities { supports_agent_permission_modes: Some(true), ..chat_client() };
        assert!(admits(&mode_event(), &declared));
    }

    #[test]
    fn usage_reports_wait_for_the_usage_flag() {
        assert!(!admits(&usage_event(), &chat_client()));
        let declared = ClientCapabilities { supports_agent_usage: Some(true), ..chat_client() };
        assert!(admits(&usage_event(), &declared));
    }

    #[test]
    fn the_other_events_need_only_agent_chat() {
        assert!(admits(&closed(), &chat_client()));
    }
}
