//! Stand-ins for the Windows adapters, used off Windows. Nothing is captured and nothing persists, so the host answers
//! clients and runs its logic, but has no picture to send.

use std::sync::Arc;

use peering_core::fakes::encoder::FakeEncoder;
use peering_core::fakes::input::RecordingInput;
use peering_core::fakes::secret_store::InMemorySecretStore;
use peering_core::fakes::capture::FakeCapture;
use peering_core::fakes::system::RecordingSystem;

use super::adapters::Adapters;
use crate::runtime::files::DiskFileSystem;
use crate::runtime::RuntimeError;

pub fn build() -> Result<Adapters, RuntimeError> {
    Ok(Adapters {
        capture: Box::new(FakeCapture::new(Vec::new())),
        encoder: Box::new(FakeEncoder::default()),
        input: Box::new(RecordingInput::default()),
        system: Box::new(RecordingSystem::new(false, None)),
        secrets: Arc::new(InMemorySecretStore::default()),
        files: Arc::new(DiskFileSystem),
    })
}
