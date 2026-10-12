//! The adapters a runtime is built from. The Windows set is compiled on Windows only; elsewhere the fakes stand in, so the
//! host logic runs and is tested on any OS. The wrappers let the video coordinator and the runtime share one capture.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_core::files::vfs::{FileSystem, FsError, RawEntry};
use peering_core::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame};
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_core::ports::input::{InputSink, TransformSnapshot};
use peering_core::ports::secret_store::SecretStore;
use peering_core::ports::system::{SystemActions, SystemError};
use peering_core::terminal::pty::PtySpawner;
use peering_core::terminal::shell::Shell;
use peering_wire::command::RemoteCommand;

mod adapters {
    #[cfg(windows)]
    pub use super::windows::build;

    #[cfg(not(windows))]
    pub use super::fakes::build;

    pub struct Adapters {
        pub capture: Box<dyn peering_core::ports::capture::Capture + Send>,
        pub encoder: Box<dyn peering_core::ports::encoder::Encoder + Send>,
        pub input: Box<dyn peering_core::ports::input::InputSink + Send>,
        pub system: Box<dyn peering_core::ports::system::SystemActions + Send>,
        pub secrets: std::sync::Arc<dyn peering_core::ports::secret_store::SecretStore + Send + Sync>,
        pub files: std::sync::Arc<dyn peering_core::files::vfs::FileSystem + Send + Sync>,
        pub terminal: super::TerminalServices,
    }
}

#[cfg(windows)]
mod windows;

#[cfg(not(windows))]
mod fakes;

use super::RuntimeError;

/// What terminals run on: the pseudo console, the shells this PC has, where a new one starts and the environment it gets.
pub struct TerminalServices {
    pub spawner: Box<dyn PtySpawner>,
    pub shells: Vec<Shell>,
    pub directory: String,
    pub environment: Vec<(String, String)>,
}

/// The adapters the runtime owns. `capture` is shared with the runtime, which lists displays through it.
pub struct HostServices {
    pub capture: Box<dyn Capture + Send>,
    pub encoder: Box<dyn Encoder + Send>,
    pub input: Box<dyn InputSink + Send>,
    pub system: Box<dyn SystemActions + Send>,
    pub secrets: Arc<dyn SecretStore + Send + Sync>,
    pub files: Arc<dyn FileSystem + Send + Sync>,
    pub terminal: TerminalServices,
    pub home_directory: String,
}

/// The capture behind a lock, so the coordinator and the runtime both reach the same device.
#[derive(Clone)]
pub struct SharedCapture(Arc<Mutex<Box<dyn Capture + Send>>>);

impl SharedCapture {
    pub fn new(capture: Box<dyn Capture + Send>) -> Self {
        Self(Arc::new(Mutex::new(capture)))
    }

    fn locked(&self) -> MutexGuard<'_, Box<dyn Capture + Send>> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn displays(&self) -> Vec<DisplayInfo> {
        self.locked().list_displays()
    }
}

impl Capture for SharedCapture {
    fn list_displays(&self) -> Vec<DisplayInfo> {
        self.displays()
    }

    fn start(&mut self, display_id: u32) -> Result<(), CaptureError> {
        self.locked().start(display_id)
    }

    fn stop(&mut self) {
        self.locked().stop();
    }

    fn poll_frame(&mut self) -> Option<RawFrame> {
        self.locked().poll_frame()
    }
}

pub struct BoxedEncoder(pub Box<dyn Encoder + Send>);

impl Encoder for BoxedEncoder {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        self.0.configure(width, height, fps, bitrate_bps)
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        self.0.encode(frame, force_keyframe)
    }

    fn set_bitrate(&mut self, bitrate_bps: u32) {
        self.0.set_bitrate(bitrate_bps);
    }
}

pub struct BoxedSystem(pub Box<dyn SystemActions + Send>);

impl SystemActions for BoxedSystem {
    fn can_lock_workstation(&self) -> bool {
        self.0.can_lock_workstation()
    }

    fn lock_workstation(&mut self) -> Result<(), SystemError> {
        self.0.lock_workstation()
    }
}

pub struct BoxedInput(pub Box<dyn InputSink + Send>);

impl InputSink for BoxedInput {
    fn apply(&mut self, command: &RemoteCommand, transform: &TransformSnapshot) {
        self.0.apply(command, transform);
    }

    fn release_all(&mut self) {
        self.0.release_all();
    }
}

/// Lets the file browser hold a shared file system.
pub struct SharedFileSystem(pub Arc<dyn FileSystem + Send + Sync>);

impl FileSystem for SharedFileSystem {
    fn list(&self, path: &str) -> Result<Vec<RawEntry>, FsError> {
        self.0.list(path)
    }

    fn read(&self, path: &str, offset: u64, limit: usize) -> Result<Vec<u8>, FsError> {
        self.0.read(path, offset, limit)
    }

    fn stat(&self, path: &str) -> Result<RawEntry, FsError> {
        self.0.stat(path)
    }

    fn roots(&self) -> Vec<String> {
        self.0.roots()
    }
}

/// The platform adapters for this machine. `home_directory` is where a file listing starts when the client names none.
pub fn platform_services(home_directory: String) -> Result<HostServices, RuntimeError> {
    let adapters::Adapters { capture, encoder, input, system, secrets, files, terminal } = adapters::build()?;
    Ok(HostServices { capture, encoder, input, system, secrets, files, terminal, home_directory })
}
