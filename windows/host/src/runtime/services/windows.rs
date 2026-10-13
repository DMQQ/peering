//! The Windows adapters: the platform capture and encoder pair, SendInput, DPAPI. Only compiled for Windows targets, and not
//! compile-checked from macOS (the host depends on ring), so this file is kept to construction and forwarding.

use std::path::PathBuf;
use std::sync::Arc;

use peering_core::ports::input::{InputSink, TransformSnapshot};
use peering_platform::dpapi::entropy::open_store;
use peering_platform::dpapi::{default_directory, DpapiSealer};
use ring::rand::{SecureRandom, SystemRandom};
use peering_platform::keyboard::KeyboardInjector;
use peering_platform::mouse::MouseInjector;
use peering_platform::services::PlatformServices;
use peering_platform::audio::LoopbackAudio;
use peering_platform::clipboard::WindowsClipboard;
use peering_platform::focus::UiaFocus;
use peering_platform::recycle::WindowsRecycleBin;
use peering_platform::system::WindowsSystem;
use peering_platform::terminal::environment::{installed_shells, start_directory};
use peering_platform::terminal::ConPtySpawner;
use peering_core::terminal::shell::terminal_environment;
use peering_wire::command::RemoteCommand;

use super::adapters::Adapters;
use crate::runtime::disk::{protected_folders, StdDisk};
use crate::runtime::files::DiskFileSystem;
use crate::runtime::{HostExtras, RuntimeError, TerminalServices};

pub fn build() -> Result<Adapters, RuntimeError> {
    let directory: PathBuf = default_directory().ok_or(RuntimeError::NoDataDirectory)?;
    let PlatformServices { capture, encoder } = PlatformServices::new();
    let secrets = open_store(directory, DpapiSealer, |bytes| SystemRandom::new().fill(bytes).is_ok())?;
    Ok(Adapters {
        capture,
        encoder,
        input: Box::new(WindowsInput { mouse: MouseInjector::default(), keyboard: KeyboardInjector::default() }),
        system: Box::new(WindowsSystem),
        secrets: Arc::new(secrets),
        files: Arc::new(DiskFileSystem),
        terminal: terminal_services(),
        rebuild_video: Arc::new(|| {
            let PlatformServices { capture, encoder } = PlatformServices::new();
            (capture, encoder)
        }),
        clipboard: Arc::new(WindowsClipboard),
        file_disk: Box::new(StdDisk::new(
            Box::new(WindowsRecycleBin),
            protected_folders(&|name| std::env::var(name).ok()),
            default_directory().map(|directory| directory.join("upload-folders.txt")),
        )),
        extras: HostExtras { audio: Box::new(LoopbackAudio::default()), focus: Box::new(UiaFocus::default()) },
    })
}

fn terminal_services() -> TerminalServices {
    let get = |name: &str| std::env::var(name).ok();
    TerminalServices {
        spawner: Box::new(ConPtySpawner),
        shells: installed_shells(&get),
        directory: start_directory(&get),
        environment: terminal_environment(std::env::vars()),
    }
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

    fn pointer_position(&self) -> Option<(f64, f64)> {
        self.mouse.pointer_position()
    }

    fn last_injected_position(&self) -> Option<(f64, f64)> {
        self.mouse.last_injected_position()
    }

    fn joystick_nudges(&self) -> u64 {
        self.mouse.joystick_nudges()
    }

    fn button_presses(&self) -> u64 {
        self.mouse.button_presses()
    }
}
