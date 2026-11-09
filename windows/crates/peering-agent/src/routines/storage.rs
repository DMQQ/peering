//! Every routine on this PC, as one JSON document the host keeps beside its other state.

use peering_wire::agent::AgentRoutine;
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex, PoisonError};

/// One routine as the host keeps it: whose it is, and when its schedule was last satisfied.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RoutineEntry {
    #[serde(rename = "ownerClientID")]
    pub owner_client_id: String,
    pub routine: AgentRoutine,
    /// Unix seconds when the routine was saved or last ran: the next time is counted from here.
    pub scheduled_from: i64,
}

/// Where the document lives. The error is a sentence for the log.
pub trait RoutineStorage {
    /// `None` for a document that was never written; an unreadable one is an error, so it is not overwritten with nothing.
    fn load(&self) -> Result<Option<String>, String>;
    /// Replaces the document whole, so a crash halfway leaves the old one.
    fn save(&self, text: &str) -> Result<(), String>;
}

pub fn decode(text: &str) -> Result<Vec<RoutineEntry>, String> {
    serde_json::from_str(text).map_err(|error| error.to_string())
}

pub fn encode(entries: &[RoutineEntry]) -> Result<String, String> {
    serde_json::to_string_pretty(entries).map_err(|error| error.to_string())
}

/// A document held in memory. Clones share it, so a test (or a host with no data folder) can start a second scheduler on it.
#[derive(Clone, Default)]
pub struct MemoryRoutineStorage {
    text: Arc<Mutex<Option<String>>>,
    fail_saves: Arc<Mutex<bool>>,
}

impl MemoryRoutineStorage {
    pub fn holding(text: &str) -> Self {
        Self { text: Arc::new(Mutex::new(Some(text.to_owned()))), fail_saves: Arc::default() }
    }

    pub fn text(&self) -> Option<String> {
        self.text.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn fail_saves(&self, fail: bool) {
        *self.fail_saves.lock().unwrap_or_else(PoisonError::into_inner) = fail;
    }
}

impl RoutineStorage for MemoryRoutineStorage {
    fn load(&self) -> Result<Option<String>, String> {
        Ok(self.text())
    }

    fn save(&self, text: &str) -> Result<(), String> {
        if *self.fail_saves.lock().unwrap_or_else(PoisonError::into_inner) {
            return Err("the disk is full".to_owned());
        }
        *self.text.lock().unwrap_or_else(PoisonError::into_inner) = Some(text.to_owned());
        Ok(())
    }
}
