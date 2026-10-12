//! The Windows adapters: desktop duplication, SendInput, DPAPI. Only compiled for Windows targets, and not
//! compile-checked from macOS (the host depends on ring), so this file is kept to construction and forwarding.
//! The H.264 encoder is not built here: `MftEncoder` needs the D3D11 device that the capture allocates, and the capture
//! does not expose it yet. Until it does, `configure` fails and no video is sent.

use std::path::PathBuf;
use std::sync::Arc;

use peering_core::ports::capture::RawFrame;
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_core::ports::input::{InputSink, TransformSnapshot};
use peering_platform::dda::DesktopDuplicationCapture;
use peering_platform::dpapi::{default_directory, DpapiProtector, DpapiStore};
use peering_platform::keyboard::KeyboardInjector;
use peering_platform::mouse::MouseInjector;
use peering_wire::command::RemoteCommand;

use super::adapters::Adapters;
use crate::runtime::files::DiskFileSystem;
use crate::runtime::RuntimeError;

pub fn build() -> Result<Adapters, RuntimeError> {
    let directory: PathBuf = default_directory().ok_or(RuntimeError::NoDataDirectory)?;
    Ok(Adapters {
        capture: Box::new(DesktopDuplicationCapture::new()),
        encoder: Box::new(UnboundEncoder),
        input: Box::new(WindowsInput { mouse: MouseInjector::default(), keyboard: KeyboardInjector::default() }),
        secrets: Arc::new(DpapiStore::new(directory, DpapiProtector)),
        files: Arc::new(DiskFileSystem),
    })
}

struct UnboundEncoder;

impl Encoder for UnboundEncoder {
    fn configure(&mut self, _width: u32, _height: u32, _fps: u32, _bitrate_bps: u32) -> Result<(), EncodeError> {
        Err(EncodeError::Unsupported("the H.264 encoder is not bound to the capture device yet".to_owned()))
    }

    fn encode(&mut self, _frame: &RawFrame, _force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        Err(EncodeError::NotConfigured)
    }

    fn set_bitrate(&mut self, _bitrate_bps: u32) {}
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
