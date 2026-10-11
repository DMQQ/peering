/// Named secrets kept on this machine (keys, pins). A failed `write` returns false and leaves the previous value in place.
/// `remove` returns true when the name holds no value afterwards, including when it held none before.
pub trait SecretStore {
    fn read(&self, name: &str) -> Option<Vec<u8>>;
    fn write(&self, name: &str, value: &[u8]) -> bool;
    fn remove(&self, name: &str) -> bool;
}
