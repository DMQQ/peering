//! The adapters a runtime is built from. The Windows set is compiled on Windows only; elsewhere the fakes stand in, so the
//! host logic runs and is tested on any OS. The wrappers let the video coordinator and the runtime share one capture.

use std::sync::{Arc, Mutex, MutexGuard};

use peering_agent::availability::BinaryLocator;
use peering_core::files::disk::DiskOps;
use peering_core::files::vfs::{FileSystem, FsError, RawEntry};
use peering_core::ports::clipboard::Clipboard;
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
        pub rebuild_video: super::RebuildVideo,
        pub clipboard: std::sync::Arc<dyn peering_core::ports::clipboard::Clipboard>,
        pub file_disk: Box<dyn peering_core::files::disk::DiskOps + Send>,
    }
}

#[cfg(windows)]
mod windows;

#[cfg(not(windows))]
mod fakes;

use super::lock::lock_ignoring_poison;
use super::RuntimeError;

/// What terminals run on: the pseudo console, the shells this PC has, where a new one starts and the environment it gets.
pub struct TerminalServices {
    pub spawner: Box<dyn PtySpawner>,
    pub shells: Vec<Shell>,
    pub directory: String,
    pub environment: Vec<(String, String)>,
}

/// A new capture and encoder on a new device, for when the pair in use is lost with a pass that never returned.
pub type RebuildVideo = Arc<dyn Fn() -> (Box<dyn Capture + Send>, Box<dyn Encoder + Send>) + Send + Sync>;

/// The adapters the runtime owns. `capture` is shared with the runtime, which lists displays through it.
pub struct HostServices {
    pub capture: Box<dyn Capture + Send>,
    pub encoder: Box<dyn Encoder + Send>,
    pub input: Box<dyn InputSink + Send>,
    pub system: Box<dyn SystemActions + Send>,
    pub secrets: Arc<dyn SecretStore + Send + Sync>,
    pub files: Arc<dyn FileSystem + Send + Sync>,
    pub terminal: TerminalServices,
    /// Builds a replacement for `capture` and `encoder` when a pass that held them never comes back.
    pub rebuild_video: RebuildVideo,
    pub home_directory: String,
    /// Answers whether the agent CLI is installed, which decides if the hello advertises chat.
    pub agent_binaries: Box<dyn BinaryLocator>,
    pub clipboard: Arc<dyn Clipboard>,
    /// Where files phones send are written, and where a delete goes.
    pub file_disk: Box<dyn DiskOps + Send>,
}

/// The capture behind a lock, so the coordinator and the runtime both reach the same device.
#[derive(Clone)]
pub struct SharedCapture(Arc<Mutex<Box<dyn Capture + Send>>>);

impl SharedCapture {
    pub fn new(capture: Box<dyn Capture + Send>) -> Self {
        Self(Arc::new(Mutex::new(capture)))
    }

    fn locked(&self) -> MutexGuard<'_, Box<dyn Capture + Send>> {
        lock_ignoring_poison(&self.0)
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

    fn is_failed(&self) -> bool {
        self.locked().is_failed()
    }

    fn probe(&mut self) -> Result<(), CaptureError> {
        self.locked().probe()
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

    fn session_notice(&self) -> Option<peering_wire::handshake::NoticePayload> {
        self.0.session_notice()
    }

    fn set_keep_awake(&mut self, awake: bool) {
        self.0.set_keep_awake(awake);
    }

    fn hardware_addresses(&self) -> Vec<String> {
        self.0.hardware_addresses()
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

    fn pointer_position(&self) -> Option<(f64, f64)> {
        self.0.pointer_position()
    }

    fn last_injected_position(&self) -> Option<(f64, f64)> {
        self.0.last_injected_position()
    }

    fn joystick_nudges(&self) -> u64 {
        self.0.joystick_nudges()
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
    let adapters::Adapters { capture, encoder, input, system, secrets, files, terminal, rebuild_video, clipboard, file_disk } = adapters::build()?;
    Ok(HostServices {
        capture,
        encoder,
        input,
        system,
        secrets,
        files,
        terminal,
        rebuild_video,
        home_directory,
        agent_binaries: Box::new(super::agent::DiskBinaries),
        clipboard,
        file_disk,
    })
}
