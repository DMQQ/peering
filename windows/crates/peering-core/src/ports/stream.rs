use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum StreamError {
    #[error("the connection is closed")]
    Closed,
}

/// The control connection as a byte pipe. Framing is the caller's job. `receive` never blocks.
pub trait ByteStream {
    /// Sends every byte in order, or fails once the connection is closed.
    fn send(&mut self, bytes: &[u8]) -> Result<(), StreamError>;
    /// The next received chunk, or None when nothing is available now.
    fn receive(&mut self) -> Result<Option<Vec<u8>>, StreamError>;
    fn close(&mut self);
    fn peer_public_key(&self) -> Option<Vec<u8>>;
}
