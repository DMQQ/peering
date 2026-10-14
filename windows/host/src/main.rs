//! The Windows host process. The runtime runs on its own thread; the tray and window run on the main thread, which
//! Windows requires for the tray.

// Without this the exe is a console program and opens a blank terminal beside the window.
#![cfg_attr(windows, windows_subsystem = "windows")]

use std::path::Path;
use std::sync::mpsc;
use std::sync::Arc;
use std::thread;

#[cfg(windows)]
use peering_host::firewall;
use peering_host::hooks::installer::HookFiles;
use peering_host::runtime::{
    platform_services, HostHandle, HostProfile, HostRuntime, RelayConfig, RuntimeConfig, RuntimeError, SettingsSaver,
    SystemClock,
};
use peering_host::settings_store::{Loaded, SettingsStore};
use peering_net::identity::HostIdentity;
use peering_platform::dpapi::default_directory;

const RELAY_URL: &str = "wss://getpeering.app/";
const FALLBACK_HOST_NAME: &str = "Windows PC";

fn main() -> Result<(), RuntimeError> {
    #[cfg(windows)]
    if let Some(port) = firewall::helper_port(&std::env::args().skip(1).collect::<Vec<_>>()) {
        // The elevated copy the host started only adds the firewall rule, and exits.
        let program = std::env::current_exe().map_err(|error| RuntimeError::Firewall(error.to_string()))?;
        return firewall::apply_rule(&program, port).map_err(|error| RuntimeError::Firewall(error.to_string()));
    }
    if let Some(directory) = default_directory() {
        // Without a log file the host still runs; there is just less to read when it misbehaves.
        drop(peering_host::logfile::install(&directory.join("logs")));
    }
    peering_host::logfile::record("peering-host started");
    let (ready, handles) = mpsc::channel();
    let host = thread::spawn(move || run_host(ready));
    match handles.recv() {
        Ok(handle) => show_ui(handle),
        // The host failed before it was ready, and its error is the one to report.
        Err(_) => host.join().unwrap_or_else(|_| Err(RuntimeError::Executor(std::io::Error::other("the host stopped")))),
    }
}

#[cfg(windows)]
fn show_ui(handle: HostHandle) -> Result<(), RuntimeError> {
    peering_host::ui::run(handle).map_err(|error| RuntimeError::Window(error.to_string()))
}

#[cfg(not(windows))]
fn show_ui(_handle: HostHandle) -> Result<(), RuntimeError> {
    // Off Windows there is no tray or window. The host keeps serving until the process is stopped.
    loop {
        thread::park();
    }
}

/// The saved settings, and the way to write the next change. Without a data folder nothing can be kept, and a change says so.
fn settings_in(directory: Option<&Path>, default_device_name: &str) -> (Loaded, SettingsSaver) {
    match directory {
        Some(directory) => {
            let store = SettingsStore::in_directory(directory);
            let loaded = store.load(default_device_name);
            let saver: SettingsSaver = Arc::new(move |settings| store.save(settings).map_err(|error| error.to_string()));
            (loaded, saver)
        }
        None => {
            let loaded = Loaded { settings: peering_core::settings::HostSettings::default_for(default_device_name), problem: None };
            (loaded, Arc::new(|_| Err("there is no data folder to keep them in".to_owned())))
        }
    }
}

fn run_host(ready: mpsc::Sender<HostHandle>) -> Result<(), RuntimeError> {
    let home_directory = std::env::var("USERPROFILE").unwrap_or_else(|_| "C:\\".to_owned());
    let computer_name = std::env::var("COMPUTERNAME").unwrap_or_else(|_| FALLBACK_HOST_NAME.to_owned());
    let data_directory = default_directory();
    let (loaded, saver) = settings_in(data_directory.as_deref(), &computer_name);
    let settings = loaded.settings;
    let host_name = settings.device_name.clone();
    let services = platform_services(home_directory.clone())?;
    let identity = HostIdentity::load(services.secrets.as_ref(), &host_name)
        .map_err(|error| RuntimeError::Identity(error.to_string()))?;
    let profile = HostProfile::from_identity(&identity, &host_name, Arc::new(SystemClock::new()));
    let relay = RelayConfig {
        url: RELAY_URL.to_owned(),
        device_id: identity.device_id().to_owned(),
        name: host_name,
    };
    let port = settings.port;
    peering_platform::cursor::set_cursor_in_picture(settings.cursor_in_picture);
    let runtime = HostRuntime::new(profile, services)?.with_settings(settings, saver, loaded.problem);
    let handle = runtime.handle();
    if ready.send(handle.clone()).is_err() {
        return Ok(());
    }
    let hook_files = data_directory.map(|directory| HookFiles::new(Path::new(&home_directory), &directory));
    let result = runtime.run(RuntimeConfig { port, relay: Some(relay), hook_files }, identity);
    // The port is bound after the handle is sent, so a bind or advertise failure reaches the window only this way.
    handle.report_stopped(result.as_ref().err().map_or_else(|| "it was stopped".to_owned(), ToString::to_string));
    result
}
