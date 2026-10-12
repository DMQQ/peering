//! The Windows adapters: the platform capture and encoder pair, SendInput, DPAPI. Only compiled for Windows targets, and not
//! compile-checked from macOS (the host depends on ring), so this file is kept to construction and forwarding.

use std::path::PathBuf;
use std::sync::Arc;

use peering_core::ports::input::{InputSink, TransformSnapshot};
use peering_platform::dpapi::{default_directory, DpapiProtector, DpapiStore};
use peering_platform::keyboard::KeyboardInjector;
use peering_platform::mouse::MouseInjector;
use peering_platform::services::PlatformServices;
use peering_wire::command::RemoteCommand;

use super::adapters::Adapters;
use crate::runtime::files::DiskFileSystem;
use crate::runtime::RuntimeError;

pub fn build() -> Result<Adapters, RuntimeError> {
    let directory: PathBuf = default_directory().ok_or(RuntimeError::NoDataDirectory)?;
    let PlatformServices { capture, encoder } = PlatformServices::new();
    Ok(Adapters {
        capture,
        encoder,
        input: Box::new(WindowsInput { mouse: MouseInjector::default(), keyboard: KeyboardInjector::default() }),
        secrets: Arc::new(DpapiStore::new(directory, DpapiProtector)),
        files: Arc::new(DiskFileSystem),
    })
}

struct WindowsInput {
    mouse: MouseInjector,
    keyboard: KeyboardInjector,
}

impl InputSink for WindowsInput {
    fn apply(&mut self, command: &RemoteCommand, transform: &TransformSnapshot) {
        self.mouse.apply(command, transform);
        self.keyboard.apply(command, transform);
    }

    fn release_all(&mut self) {
        self.mouse.release_all();
        self.keyboard.release_all();
    }
}
