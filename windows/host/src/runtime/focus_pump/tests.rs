use std::sync::Arc;

use peering_core::fakes::focus::ScriptedFocus;
use peering_core::ports::focus::{FocusReport, FocusSnapshot};
use peering_wire::framing::MessageKind;
use peering_wire::handshake::ClientCapabilities;
use peering_wire::text_focus::{FieldState, TextFocus};

use super::super::services::platform_services;
use super::super::shared::SessionSlot;
use super::super::test_support::slot;
use super::super::video::Outgoing;
use super::super::{HostProfile, HostRuntime, SystemClock};

fn runtime_with(focus: &ScriptedFocus) -> HostRuntime {
    let mut services = platform_services(String::new()).expect("the stand-in adapters build");
    services.extras.focus = Box::new(focus.clone());
    let profile = HostProfile {
        host_id: "host".to_owned(),
        host_name: "PC".to_owned(),
        identity_public_key: Vec::new(),
        mac_addresses: Vec::new(),
        clock: Arc::new(SystemClock::new()),
    };
    HostRuntime::new(profile, services).expect("the runtime builds")
}

fn phone(text_focus: bool, field_state: bool) -> SessionSlot {
    let flags = ClientCapabilities {
        supports_text_focus: text_focus.then_some(true),
        supports_field_state: field_state.then_some(true),
        ..ClientCapabilities::default()
    };
    SessionSlot { client_flags: flags, ..slot("phone") }
}

fn label(element: u64) -> FocusSnapshot {
    FocusSnapshot { element, editable: false, secure: false, terminal: false, text: None, selection: None, caret: None }
}

fn field(element: u64, text: &str) -> FocusSnapshot {
    FocusSnapshot {
        element,
        editable: true,
        text: Some(text.to_owned()),
        selection: Some((text.len() as u32, 0)),
        ..label(element)
    }
}

fn kinds(outgoing: &[Outgoing]) -> Vec<MessageKind> {
    outgoing.iter().map(|item| item.frame.kind).collect()
}

#[test]
fn a_phone_that_asked_for_neither_is_not_watched_for() {
    let focus = ScriptedFocus::default();
    let runtime = runtime_with(&focus);
    runtime.shared.lock().sessions.insert(1, phone(false, false));
    focus.report(FocusReport::Focus(Some(label(1))));
    assert!(runtime.shared.lock().pump_focus().is_empty());
    assert!(!focus.is_active());
}

#[test]
fn watching_starts_with_the_first_phone_that_asked_and_stops_with_the_last() {
    let focus = ScriptedFocus::default();
    let runtime = runtime_with(&focus);
    runtime.shared.lock().sessions.insert(1, phone(true, false));
    runtime.shared.lock().pump_focus();
    assert!(focus.is_active());
    runtime.shared.lock().sessions.clear();
    runtime.shared.lock().pump_focus();
    assert_eq!(focus.activations(), vec![true, false]);
}

#[test]
fn a_move_into_a_field_sends_text_focus_and_then_field_state() {
    let focus = ScriptedFocus::default();
    let runtime = runtime_with(&focus);
    runtime.shared.lock().sessions.insert(1, phone(true, true));
    runtime.shared.lock().pump_focus();
    focus.report(FocusReport::Focus(Some(label(1))));
    assert!(runtime.shared.lock().pump_focus().is_empty(), "the baseline is not sent");
    focus.report(FocusReport::Focus(Some(field(2, "hi"))));
    let sent = runtime.shared.lock().pump_focus();
    assert_eq!(kinds(&sent), vec![MessageKind::TextFocus, MessageKind::FieldState]);
    assert_eq!(serde_json::from_slice::<TextFocus>(&sent[0].frame.payload).expect("json"), TextFocus { is_editable: true });
    let state: FieldState = serde_json::from_slice(&sent[1].frame.payload).expect("json");
    assert_eq!((state.text.as_deref(), state.selection_location), (Some("hi"), 2));
}

#[test]
fn each_phone_gets_only_the_frames_it_declared() {
    let focus = ScriptedFocus::default();
    let runtime = runtime_with(&focus);
    runtime.shared.lock().sessions.insert(1, phone(true, false));
    runtime.shared.lock().sessions.insert(2, phone(false, true));
    runtime.shared.lock().pump_focus();
    focus.report(FocusReport::Focus(Some(label(1))));
    runtime.shared.lock().pump_focus();
    focus.report(FocusReport::Focus(Some(field(2, "x"))));
    let sent = runtime.shared.lock().pump_focus();
    assert_eq!(kinds(&sent), vec![MessageKind::TextFocus, MessageKind::FieldState]);
}
