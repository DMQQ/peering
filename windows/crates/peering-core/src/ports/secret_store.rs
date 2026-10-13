/// Named secrets kept on this machine (keys, pins). `read` returns `Ok(None)` only when the name holds no value,
/// and `Err` when a value may exist but cannot be read: callers must not treat that as absence.
/// A failed `write` returns false and leaves the previous value in place.
/// `remove` returns true when the name holds no value afterwards, including when it held none before.
pub trait SecretStore {
    fn read(&self, name: &str) -> Result<Option<Vec<u8>>, StoreError>;
    fn write(&self, name: &str, value: &[u8]) -> bool;
    fn remove(&self, name: &str) -> bool;
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("the stored secret could not be read")]
pub struct StoreError;
