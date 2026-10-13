use super::*;
use serde::{de::DeserializeOwned, Serialize};
use serde_json::Value;

const SESSION_ID: &str = "0A1B2C3D-0000-4000-8000-00000000000F";

/// Decodes the Swift JSON and checks that encoding the model gives the same JSON back.
fn assert_wire<T>(json: &str)
where
    T: Serialize + DeserializeOwned,
{
    let expected: Value = serde_json::from_str(json).expect("the literal is JSON");
    let decoded: T = serde_json::from_value(expected.clone()).expect("the literal decodes");
    assert_eq!(serde_json::to_value(&decoded).expect("the model encodes"), expected);
}

fn requests() -> Vec<String> {
    vec![
        r#"{"list":{}}"#.to_string(),
        r#"{"agents":{}}"#.to_string(),
        r#"{"create":{}}"#.to_string(),
        format!(r#"{{"input":{{"sessionID":"{SESSION_ID}","data":"aGkK"}}}}"#),
        format!(r#"{{"resize":{{"sessionID":"{SESSION_ID}","columns":120,"rows":40}}}}"#),
        format!(r#"{{"rename":{{"sessionID":"{SESSION_ID}","name":"build"}}}}"#),
        format!(r#"{{"retitle":{{"sessionID":"{SESSION_ID}","command":"npm test"}}}}"#),
        format!(r#"{{"close":{{"sessionID":"{SESSION_ID}"}}}}"#),
        format!(r#"{{"startBrowser":{{"id":"{SESSION_ID}"}}}}"#),
        format!(r#"{{"listDirectory":{{"sessionID":"{SESSION_ID}","path":"/Users/me"}}}}"#),
        format!(r#"{{"readFile":{{"sessionID":"{SESSION_ID}","path":"/Users/me/notes.txt"}}}}"#),
        format!(r#"{{"readRange":{{"sessionID":"{SESSION_ID}","path":"/Users/me/movie.mov","offset":1048576}}}}"#),
        format!(r#"{{"archiveFolder":{{"sessionID":"{SESSION_ID}","path":"/Users/me/Projects"}}}}"#),
        format!(r#"{{"beginWrite":{{"sessionID":"{SESSION_ID}","path":"/Users/me/a.txt","totalBytes":5}}}}"#),
        format!(r#"{{"writeChunk":{{"sessionID":"{SESSION_ID}","path":"/Users/me/a.txt","data":"aGVsbG8=","isLast":true}}}}"#),
        format!(
            r#"{{"changeFile":{{"sessionID":"{SESSION_ID}","operation":{{"create":{{"path":"/Users/me/new","kind":"folder"}}}}}}}}"#
        ),
        r#"{"registerPushToken":{"_0":"ZmNtOmFiYw=="}}"#.to_string(),
    ]
}

#[test]
fn every_terminal_request_case_round_trips() {
    for request in requests() {
        assert_wire::<TerminalRequest>(&request);
    }
}

#[test]
fn a_list_directory_without_a_path_omits_the_key() {
    assert_wire::<TerminalRequest>(&format!(r#"{{"listDirectory":{{"sessionID":"{SESSION_ID}"}}}}"#));
}

#[test]
fn a_push_token_carries_the_android_fcm_prefix_as_its_bytes() {
    let request: TerminalRequest =
        serde_json::from_str(r#"{"registerPushToken":{"_0":"ZmNtOmFiYw=="}}"#).expect("decodes");
    assert_eq!(request, TerminalRequest::RegisterPushToken { token: b"fcm:abc".to_vec() });
}

#[test]
fn an_unknown_terminal_request_case_is_an_error_not_a_panic() {
    assert!(serde_json::from_str::<TerminalRequest>(r#"{"teleport":{}}"#).is_err());
}

#[test]
fn a_terminal_session_info_round_trips_with_and_without_its_grid() {
    assert_wire::<TerminalSessionInfo>(
        r#"{"id":"0A1B2C3D-0000-4000-8000-00000000000F","name":"zsh","isRunning":true,"columns":80,"rows":24,"createdAt":812979000.0}"#,
    );
    let older = r#"{"id":"0A1B2C3D-0000-4000-8000-00000000000F","name":"zsh","isRunning":false}"#;
    let info: TerminalSessionInfo = serde_json::from_str(older).expect("an older Mac's listing decodes");
    assert_eq!(info.columns, None);
    assert_eq!(info.rows, None);
    assert_eq!(info.created_at, None);
    assert_wire::<TerminalSessionInfo>(older);
}

#[test]
fn every_terminal_event_case_round_trips() {
    let session = r#"{"id":"0A1B2C3D-0000-4000-8000-00000000000F","name":"zsh","isRunning":true}"#;
    let cases = [
        format!(r#"{{"snapshot":{{"_0":[{session}]}}}}"#),
        r#"{"agents":{"installed":["claude","codex"]}}"#.to_string(),
        format!(r#"{{"created":{{"_0":{session}}}}}"#),
        format!(r#"{{"renamed":{{"_0":{session}}}}}"#),
        format!(r#"{{"output":{{"sessionID":"{SESSION_ID}","data":"G1swbQ=="}}}}"#),
        format!(r#"{{"attention":{{"sessionID":"{SESSION_ID}","kind":"password","message":"Password:"}}}}"#),
        format!(
            r#"{{"commandFinished":{{"sessionID":"{SESSION_ID}","command":"make","duration":12.5,"exitStatus":2}}}}"#
        ),
        format!(r#"{{"commandFinished":{{"sessionID":"{SESSION_ID}","duration":0.5,"exitStatus":0}}}}"#),
        format!(r#"{{"exited":{{"sessionID":"{SESSION_ID}","status":0}}}}"#),
        format!(r#"{{"closed":{{"sessionID":"{SESSION_ID}"}}}}"#),
        format!(
            r#"{{"directory":{{"sessionID":"{SESSION_ID}","path":"/Users/me","entries":[{{"name":"src","isDirectory":true,"isSymlink":false,"size":96,"permissions":"drwxr-xr-x","modified":812979000.0}}],"truncated":false}}}}"#
        ),
        format!(
            r#"{{"fileContents":{{"sessionID":"{SESSION_ID}","path":"/Users/me/a.txt","kind":"text","offset":0,"totalBytes":5,"data":"aGVsbG8=","isLast":true}}}}"#
        ),
        format!(
            r#"{{"fileRange":{{"sessionID":"{SESSION_ID}","path":"/Users/me/movie.mov","offset":1048576,"totalBytes":2097152,"data":"AQI="}}}}"#
        ),
        format!(
            r#"{{"archiveReady":{{"sessionID":"{SESSION_ID}","folder":"/Users/me/Projects","archivePath":"/tmp/p.zip","totalBytes":900}}}}"#
        ),
        format!(r#"{{"transferFailure":{{"sessionID":"{SESSION_ID}","path":"/a","message":"Too large"}}}}"#),
        format!(r#"{{"browseFailure":{{"sessionID":"{SESSION_ID}","path":"/root","message":"Denied"}}}}"#),
        format!(r#"{{"wroteFile":{{"sessionID":"{SESSION_ID}","path":"/a.txt","totalBytes":5}}}}"#),
        format!(r#"{{"writeFailure":{{"sessionID":"{SESSION_ID}","path":"/a.txt","message":"Disk full"}}}}"#),
        format!(r#"{{"fileOperationDone":{{"sessionID":"{SESSION_ID}","path":"/a.txt","note":"Renamed"}}}}"#),
        format!(
            r#"{{"fileOperationFailure":{{"sessionID":"{SESSION_ID}","path":"/a.txt","message":"Exists"}}}}"#
        ),
        r#"{"failed":{"message":"No Mac answered"}}"#.to_string(),
        format!(r#"{{"failed":{{"sessionID":"{SESSION_ID}","message":"Shell exited"}}}}"#),
    ];
    for case in cases {
        assert_wire::<TerminalEvent>(&case);
    }
}

#[test]
fn an_unknown_terminal_event_case_is_an_error_not_a_panic() {
    assert!(serde_json::from_str::<TerminalEvent>(r#"{"teleport":{}}"#).is_err());
}

#[test]
fn a_command_finished_without_a_command_decodes_as_none() {
    let event: TerminalEvent = serde_json::from_str(&format!(
        r#"{{"commandFinished":{{"sessionID":"{SESSION_ID}","duration":1.0,"exitStatus":0}}}}"#
    ))
    .expect("decodes");
    assert!(matches!(event, TerminalEvent::CommandFinished { command: None, .. }));
}
