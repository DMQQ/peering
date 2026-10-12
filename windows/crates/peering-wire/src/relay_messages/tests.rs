use super::*;
use crate::vectors_dir::load;

fn typed_client_message(name: &str) -> RelayClientMessage {
    match name {
        "registerHost" => RelayClientMessage::RegisterHost {
            device_id: "mac-1".into(),
            name: "Studio".into(),
            protocol_version: 3,
            public_key: None,
            proof: None,
            proof_time: None,
        },
        "connectToHost free" => connect_to_host(None),
        "connectToHost plan" => connect_to_host(Some("relay")),
        "ping" => RelayClientMessage::Ping,
        "requestPeerAddress" => RelayClientMessage::RequestPeerAddress {
            video_token: "000102030405060708090a0b0c0d0e0f".into(),
        },
        "hostPresence" => RelayClientMessage::HostPresence { host_id: "mac-1".into() },
        "notifyDevice" => RelayClientMessage::NotifyDevice {
            device_token: "ab".repeat(32),
            title: "t".into(),
            body: "b".into(),
            source: None,
            category: None,
            session_id: None,
            approval_id: None,
        },
        "notifyActivity update" => RelayClientMessage::NotifyActivity {
            activity_token: "0a1b2c".into(),
            activity: ActivityKind::Session,
            event: ActivityEvent::Update,
            content_state: serde_json::json!({"phase": "active", "startedAt": 800000000}),
            stale_seconds: None,
            priority: None,
            attributes_type: None,
            attributes: None,
            alert_title: None,
            alert_body: None,
            environment: Some(ActivityEnvironment::Production),
            dismissal_seconds: None,
            request_id: None,
        },
        other => panic!("no typed message for vector {other}"),
    }
}

fn connect_to_host(plan: Option<&str>) -> RelayClientMessage {
    RelayClientMessage::ConnectToHost {
        host_id: "mac-1".into(),
        client_id: "phone-1".into(),
        protocol_version: 3,
        api_key: None,
        plan: plan.map(str::to_string),
        jws_representation: None,
        public_key: None,
        proof: None,
        proof_time: None,
        play_purchase_token: None,
        play_product_id: None,
    }
}

fn typed_server_message(name: &str) -> RelayServerMessage {
    match name {
        "sessionReady" => RelayServerMessage::SessionReady {
            control_host: "relay.getpeering.app".into(),
            control_port: 20190,
            video_host: "relay.getpeering.app".into(),
            video_port: 30190,
            control_token: Token(std::array::from_fn(|index| index as u8)),
            video_token: Token(std::array::from_fn(|index| 0xff - index as u8)),
            remaining_seconds: None,
        },
        "registered" => RelayServerMessage::Registered { session_ttl_seconds: 300 },
        "hostOffline" => RelayServerMessage::HostOffline { device_id: "mac-1".into() },
        "peerAddress" => RelayServerMessage::PeerAddress { host: "203.0.113.5".into(), port: 40000 },
        "hostPresence" => RelayServerMessage::HostPresence { host_id: "mac-1".into(), online: true },
        "pong" => RelayServerMessage::Pong,
        "error" => RelayServerMessage::Error {
            code: "quotaExceeded".into(),
            message: "relay allowance exhausted for this period".into(),
        },
        "activityRefused" => RelayServerMessage::ActivityRefused {
            reason: "invalidToken".into(),
            request_id: None,
        },
        other => panic!("no typed message for vector {other}"),
    }
}

fn vector_entries(section: &str) -> Vec<(String, String)> {
    let vectors = load("relay.json");
    vectors[section]
        .as_array()
        .expect("section is a list")
        .iter()
        .map(|entry| {
            (
                entry["name"].as_str().expect("name").to_string(),
                entry["json"].as_str().expect("json").to_string(),
            )
        })
        .collect()
}

#[test]
fn every_client_vector_serialises_to_its_exact_json() {
    let entries = vector_entries("clientMessages");
    assert_eq!(entries.len(), 8);
    for (name, json) in entries {
        assert_eq!(encode_sorted(&typed_client_message(&name)), json, "vector {name}");
    }
}

#[test]
fn every_server_vector_decodes_to_the_typed_message() {
    let entries = vector_entries("serverMessages");
    assert_eq!(entries.len(), 8);
    for (name, json) in entries {
        let decoded: RelayServerMessage = serde_json::from_str(&json).expect("vector decodes");
        assert_eq!(decoded, typed_server_message(&name), "vector {name}");
    }
}

#[test]
fn valid_tokens_parse_and_print_lowercase() {
    let vectors = load("relay.json");
    for text in vectors["tokens"]["valid"].as_array().expect("valid list") {
        let text = text.as_str().expect("token text");
        let token = Token::parse(text).expect("valid token parses");
        assert_eq!(token.to_hex(), text.to_ascii_lowercase());
    }
}

#[test]
fn invalid_tokens_are_refused() {
    let vectors = load("relay.json");
    for text in vectors["tokens"]["invalid"].as_array().expect("invalid list") {
        let text = text.as_str().expect("token text");
        assert!(Token::parse(text).is_none(), "accepted {text:?}");
    }
}

#[test]
fn a_session_ready_with_a_bad_token_fails_to_decode() {
    let json = r#"{"type":"sessionReady","controlHost":"h","controlPort":1,"videoHost":"h","videoPort":2,"controlToken":"+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1","videoToken":"000102030405060708090a0b0c0d0e0f"}"#;
    assert!(serde_json::from_str::<RelayServerMessage>(json).is_err());
}

#[test]
fn a_session_ready_decodes_with_and_without_remaining_seconds() {
    let base = r#""type":"sessionReady","controlHost":"h","controlPort":1,"videoHost":"h","videoPort":2,"controlToken":"000102030405060708090a0b0c0d0e0f","videoToken":"000102030405060708090a0b0c0d0e0f""#;
    let remaining = |json: String| match serde_json::from_str::<RelayServerMessage>(&json).expect("decodes") {
        RelayServerMessage::SessionReady { remaining_seconds, .. } => remaining_seconds,
        other => panic!("expected a session, got {other:?}"),
    };
    assert_eq!(remaining(format!("{{{base}}}")), None);
    assert_eq!(remaining(format!("{{{base},\"remainingSeconds\":1703}}")), Some(1703));
}

#[test]
fn unknown_server_type_decodes_as_unknown() {
    let decoded: RelayServerMessage =
        serde_json::from_str(r#"{"type":"somethingNew","extra":1}"#).expect("unknown type decodes");
    assert_eq!(decoded, RelayServerMessage::Unknown);
}

#[test]
fn unset_optional_fields_are_absent_from_the_json() {
    let message = RelayClientMessage::RegisterHost {
        device_id: "d".into(),
        name: "n".into(),
        protocol_version: 20,
        public_key: None,
        proof: None,
        proof_time: None,
    };
    assert_eq!(
        encode_sorted(&message),
        r#"{"deviceId":"d","name":"n","protocolVersion":20,"type":"registerHost"}"#
    );
}

#[test]
fn set_optional_fields_appear_in_the_json() {
    let message = RelayClientMessage::RegisterHost {
        device_id: "d".into(),
        name: "n".into(),
        protocol_version: 20,
        public_key: Some("04aa".into()),
        proof: Some("3044".into()),
        proof_time: Some(1760000000),
    };
    assert_eq!(
        encode_sorted(&message),
        r#"{"deviceId":"d","name":"n","proof":"3044","proofTime":1760000000,"protocolVersion":20,"publicKey":"04aa","type":"registerHost"}"#
    );
}

#[test]
fn notify_activity_serialises_camel_case_and_round_trips() {
    let text = r#"{"activity":"agentChat","activityToken":"0a1b","alertBody":"b","alertTitle":"t","contentState":{"n":1},"environment":"sandbox","event":"update","priority":10,"staleSeconds":120,"type":"notifyActivity"}"#;
    let message: RelayClientMessage = serde_json::from_str(text).expect("decodes");
    assert!(matches!(
        &message,
        RelayClientMessage::NotifyActivity { activity: ActivityKind::AgentChat, event: ActivityEvent::Update, stale_seconds: Some(120), environment: Some(ActivityEnvironment::Sandbox), .. }
    ));
    assert_eq!(encode_sorted(&message), text);
}

#[test]
fn notify_activity_omits_absent_optionals() {
    let message = RelayClientMessage::NotifyActivity {
        activity_token: "0a".into(),
        activity: ActivityKind::Terminal,
        event: ActivityEvent::End,
        content_state: serde_json::json!({}),
        stale_seconds: None,
        priority: None,
        attributes_type: None,
        attributes: None,
        alert_title: None,
        alert_body: None,
        environment: None,
        dismissal_seconds: None,
        request_id: None,
    };
    assert_eq!(
        encode_sorted(&message),
        r#"{"activity":"terminal","activityToken":"0a","contentState":{},"event":"end","type":"notifyActivity"}"#
    );
}

#[test]
fn activity_refused_decodes_with_any_reason() {
    let decoded: RelayServerMessage = serde_json::from_str(r#"{"type":"activityRefused","reason":"invalidToken"}"#).expect("decodes");
    assert_eq!(decoded, RelayServerMessage::ActivityRefused { reason: "invalidToken".into(), request_id: None });
}

#[test]
fn activity_refused_decodes_the_echoed_request_id() {
    let decoded: RelayServerMessage = serde_json::from_str(r#"{"type":"activityRefused","reason":"rejected","requestId":"r-1"}"#).expect("decodes");
    assert_eq!(decoded, RelayServerMessage::ActivityRefused { reason: "rejected".into(), request_id: Some("r-1".into()) });
}

#[test]
fn notify_activity_carries_dismissal_seconds_and_request_id() {
    let text = r#"{"activity":"session","activityToken":"0a","contentState":{},"dismissalSeconds":1800,"event":"end","requestId":"r-1","type":"notifyActivity"}"#;
    let message: RelayClientMessage = serde_json::from_str(text).expect("decodes");
    assert!(matches!(&message, RelayClientMessage::NotifyActivity { dismissal_seconds: Some(1800), request_id: Some(id), .. } if id == "r-1"));
    assert_eq!(encode_sorted(&message), text);
}
