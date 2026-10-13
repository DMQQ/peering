use serde_json::{json, Value};

use super::*;

const COMMAND: &str = "\"C:/Users/x/AppData/Local/Peering Host/peering-hook.cmd\"";

fn object(value: Value) -> Map<String, Value> {
    value.as_object().cloned().expect("an object literal")
}

fn mine() -> Value {
    json!({ "hooks": { "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "/usr/local/bin/mine" }] }] } })
}

#[test]
fn installing_keeps_everything_else() {
    let mut existing = object(mine());
    existing.insert("model".to_owned(), json!("opus"));
    let result = installing(COMMAND, &existing).expect("installs");
    assert_eq!(result["model"], "opus");
    assert_eq!(result["hooks"]["PermissionRequest"].as_array().map(Vec::len), Some(2));
    assert!(is_installed(&result));
}

#[test]
fn installing_twice_does_not_duplicate() {
    let once = installing(COMMAND, &Map::new()).expect("installs");
    let twice = installing(COMMAND, &once).expect("installs again");
    assert_eq!(twice["hooks"]["PermissionRequest"].as_array().map(Vec::len), Some(1));
    assert_eq!(twice["hooks"]["Notification"][0]["matcher"], "idle_prompt|elicitation_dialog");
    assert_eq!(twice["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"], 600);
}

#[test]
fn removing_leaves_the_users_own_hooks_and_drops_empty_events() {
    let installed = installing(COMMAND, &object(mine())).expect("installs");
    let removed = removing(&installed).expect("removes");
    assert!(removed["hooks"].get("Notification").is_none());
    assert_eq!(removed["hooks"]["PermissionRequest"].as_array().map(Vec::len), Some(1));
    assert!(!is_installed(&removed));
}

#[test]
fn removing_from_an_empty_file_leaves_it_empty() {
    let installed = installing(COMMAND, &Map::new()).expect("installs");
    assert!(removing(&installed).expect("removes").is_empty());
}

#[test]
fn a_shape_it_does_not_know_is_refused() {
    let hooks_text = object(json!({ "hooks": "nope" }));
    assert_eq!(installing(COMMAND, &hooks_text), Err(UnexpectedShape("hooks".to_owned())));
    let event_text = object(json!({ "hooks": { "Notification": "nope" } }));
    assert_eq!(installing(COMMAND, &event_text), Err(UnexpectedShape("hooks.Notification".to_owned())));
}

#[test]
fn a_group_it_does_not_understand_is_kept_when_removing() {
    let odd = object(json!({ "hooks": { "Stop": [{ "matcher": "x" }] } }));
    let removed = removing(&installing(COMMAND, &odd).expect("installs")).expect("removes");
    assert_eq!(removed["hooks"]["Stop"], json!([{ "matcher": "x" }]));
}

#[test]
fn a_half_installed_file_is_not_installed() {
    let only_permission = object(json!({ "hooks": { "PermissionRequest": [{ "hooks": [{ "command": COMMAND }] }] } }));
    assert!(!is_installed(&only_permission));
}
