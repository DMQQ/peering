#![allow(dead_code)]

use std::cell::RefCell;
use std::collections::HashMap;

use peering_core::ports::secret_store::{SecretStore, StoreError};

pub mod client;

#[derive(Default)]
pub struct MemorySecrets {
    values: RefCell<HashMap<String, Vec<u8>>>,
    refuse_writes: bool,
    refused_reads: Vec<String>,
}

impl MemorySecrets {
    pub fn with_value(self, name: &str, value: &[u8]) -> Self {
        self.values.borrow_mut().insert(name.to_owned(), value.to_vec());
        self
    }

    pub fn refusing_writes(self) -> Self {
        Self { refuse_writes: true, ..self }
    }

    pub fn refusing_reads_of(mut self, name: &str) -> Self {
        self.refused_reads.push(name.to_owned());
        self
    }

    pub fn value(&self, name: &str) -> Option<Vec<u8>> {
        self.values.borrow().get(name).cloned()
    }
}

impl SecretStore for MemorySecrets {
    fn read(&self, name: &str) -> Result<Option<Vec<u8>>, StoreError> {
        if self.refused_reads.iter().any(|refused| refused == name) {
            return Err(StoreError);
        }
        Ok(self.values.borrow().get(name).cloned())
    }

    fn write(&self, name: &str, value: &[u8]) -> bool {
        if self.refuse_writes {
            return false;
        }
        self.values.borrow_mut().insert(name.to_owned(), value.to_vec());
        true
    }

    fn remove(&self, name: &str) -> bool {
        self.values.borrow_mut().remove(name);
        true
    }
}
