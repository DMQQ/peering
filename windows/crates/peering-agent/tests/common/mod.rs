//! The scripted Claude Code process and the chat helpers the agent flow tests share.
#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_agent::claude_adapter::{ChildProcess, LaunchSpec, ProcessLauncher, ReadResult};
use peering_agent::manager::AgentSessionManager;
use peering_wire::agent::{AgentEvent, AgentRequest, AgentSessionInfo, AgentStreamEvent, AgentStreamPayload};
use serde_json::{json, Value};

pub const APPROVAL_ID: &str = "49f17c21-744b-4bc7-a5ee-4ecf7225a13c";

#[derive(Debug, Default)]
pub struct Script {
    pub output: std::collections::VecDeque<String>,
    pub closed: bool,
    pub written: Vec<String>,
    pub interrupts: usize,
    pub launches: Vec<LaunchSpec>,
}

pub type SharedScript = Arc<Mutex<Script>>;

pub fn locked(script: &SharedScript) -> MutexGuard<'_, Script> {
    script.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A child process that prints the scripted lines and records what it is sent.
pub struct ScriptedChild(pub SharedScript);

impl ChildProcess for ScriptedChild {
    fn write_line(&mut self, line: &str) -> bool {
        locked(&self.0).written.push(line.to_owned());
        true
    }

    fn read_line(&mut self) -> ReadResult {
        let mut script = locked(&self.0);
        match script.output.pop_front() {
            Some(line) => ReadResult::Line(line),
            None if script.closed => ReadResult::Closed,
            None => ReadResult::Pending,
        }
    }

    fn interrupt(&mut self) {
        locked(&self.0).interrupts += 1;
    }

    fn kill(&mut self) {
        locked(&self.0).closed = true;
    }

    fn exit_status(&mut self) -> Option<i32> {
        locked(&self.0).closed.then_some(0)
    }
}

pub struct ScriptedLauncher(pub SharedScript);

impl ProcessLauncher for ScriptedLauncher {
    fn spawn(&mut self, command: LaunchSpec) -> Box<dyn ChildProcess> {
        locked(&self.0).launches.push(command);
        Box::new(ScriptedChild(Arc::clone(&self.0)))
    }
}

pub struct Chat {
    pub manager: AgentSessionManager<ScriptedLauncher>,
    pub script: SharedScript,
    pub session_id: String,
}

pub fn fixture(name: &str) -> Vec<String> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/claude").join(name);
    std::fs::read_to_string(path)
        .expect("fixture is checked in")
        .lines()
        .map(str::to_owned)
        .collect()
}

pub fn start_chat() -> Chat {
    let script = SharedScript::default();
    let mut manager = AgentSessionManager::new(ScriptedLauncher(Arc::clone(&script)));
    let directory = std::env::temp_dir().join("peering-agent-turn-flow");
    let events = manager.handle(AgentRequest::Start {
        agent_id: "claude".to_owned(),
        directory: Some(directory.to_string_lossy().into_owned()),
    });
    let [AgentEvent::Created { session }] = events.as_slice() else {
        panic!("expected a created chat, got {events:?}");
    };
    Chat { manager, script, session_id: session.id.clone() }
}

impl Chat {
    pub fn push_output(&self, lines: &[String]) {
        locked(&self.script).output.extend(lines.iter().cloned());
    }

    pub fn poll(&mut self) -> Vec<AgentEvent> {
        self.manager.poll()
    }

    pub fn written(&self) -> Vec<Value> {
        locked(&self.script)
            .written
            .iter()
            .map(|line| serde_json::from_str(line).expect("the CLI is sent JSON lines"))
            .collect()
    }

    pub fn info(&mut self) -> AgentSessionInfo {
        match self.manager.handle(AgentRequest::List {}).as_slice() {
            [AgentEvent::Snapshot { sessions }] => sessions
                .iter()
                .find(|session| session.id == self.session_id)
                .cloned()
                .expect("the chat is listed"),
            other => panic!("expected a snapshot, got {other:?}"),
        }
    }

    pub fn stream_payloads(events: &[AgentEvent]) -> Vec<AgentStreamPayload> {
        events
            .iter()
            .filter_map(|event| match event {
                AgentEvent::Stream { event, .. } => Some(event.payload.clone()),
                _ => None,
            })
            .collect()
    }

    pub fn stream_events(events: &[AgentEvent]) -> Vec<AgentStreamEvent> {
        events
            .iter()
            .filter_map(|event| match event {
                AgentEvent::Stream { event, .. } => Some(event.clone()),
                _ => None,
            })
            .collect()
    }
}

/// A `can_use_tool` ask in the shape the CLI prints, with the request id chosen by the test.
pub fn bash_ask(request_id: &str) -> String {
    json!({
        "type": "control_request",
        "request_id": request_id,
        "request": {
            "subtype": "can_use_tool",
            "tool_name": "Bash",
            "display_name": "Bash",
            "input": {"command": "rm -f notes.txt", "description": "Remove notes.txt"},
            "description": "Remove notes.txt",
        },
    })
    .to_string()
}

pub fn approval_id_of(payloads: &[AgentStreamPayload]) -> Option<String> {
    payloads.iter().find_map(|payload| match payload {
        AgentStreamPayload::ApprovalRequested { approval_id, .. } => Some(approval_id.clone()),
        _ => None,
    })
}

