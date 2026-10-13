//! Why the host runtime could not start or had to stop.

use std::io;

use peering_core::ports::secret_store::StoreError;

#[derive(Debug, thiserror::Error)]
pub enum RuntimeError {
    #[error("the data directory is not set (LOCALAPPDATA is missing)")]
    NoDataDirectory,
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Entropy(#[from] peering_core::install_entropy::EntropyError),
    #[error("the host identity could not be loaded: {0}")]
    Identity(String),
    #[error("the transport certificate could not be built: {0}")]
    Tls(String),
    #[error("port {port} could not be opened: {source}")]
    Bind { port: u16, source: io::Error },
    #[error("the host could not be announced on the network: {0}")]
    Advertise(String),
    #[error("the async runtime could not start: {0}")]
    Executor(io::Error),
    #[error("the {task} stopped: {reason}")]
    TaskStopped { task: &'static str, reason: String },
    #[error("the window could not start: {0}")]
    Window(String),
    #[error("the firewall rule could not be added: {0}")]
    Firewall(String),
}
