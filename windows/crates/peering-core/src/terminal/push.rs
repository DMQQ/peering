//! Where the manager gets a phone's push token, and what it hands the host to send.

use crate::ports::secret_store::SecretStore;
use crate::push_tokens::PushTokenStore;

pub trait PushTokens {
    /// Stores the token for a client, or forgets it when `bytes` is empty. False when the change was not saved.
    fn register(&self, client_id: &str, bytes: &[u8]) -> bool;
    fn token_for(&self, client_id: &str) -> Option<String>;
    /// Every stored token, for a notification that is for whichever phone is paired.
    fn all_tokens(&self) -> Vec<String>;
}

impl<S: SecretStore> PushTokens for PushTokenStore<S> {
    fn register(&self, client_id: &str, bytes: &[u8]) -> bool {
        PushTokenStore::register(self, client_id, bytes)
    }

    fn token_for(&self, client_id: &str) -> Option<String> {
        PushTokenStore::token_for(self, client_id)
    }

    fn all_tokens(&self) -> Vec<String> {
        PushTokenStore::all(self).into_values().collect()
    }
}

impl<T: PushTokens + ?Sized> PushTokens for std::sync::Arc<T> {
    fn register(&self, client_id: &str, bytes: &[u8]) -> bool {
        (**self).register(client_id, bytes)
    }

    fn token_for(&self, client_id: &str) -> Option<String> {
        (**self).token_for(client_id)
    }

    fn all_tokens(&self) -> Vec<String> {
        (**self).all_tokens()
    }
}

/// A notification for a phone that has no connection to be told on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushAlert {
    pub token: String,
    pub title: String,
    pub message: String,
}

/// Which of the known coding agents are installed on this machine.
pub trait AgentLocator {
    fn installed(&self, names: &[&str]) -> Vec<String>;
}
