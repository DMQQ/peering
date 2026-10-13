//! Running the host: binding the port, announcing the host, and keeping the pumps and the relay alive.

use std::rc::Rc;
use std::sync::Arc;

use peering_net::identity::HostIdentity;
use peering_net::tls::HostTls;
use tokio::net::TcpListener;
use tokio::task::{JoinHandle, LocalSet};

use super::lock::lock_ignoring_poison;
use super::{
    advertise, agent_pump, audio, focus_pump, listener, pointer_pump, update, relay_switch, supervise, video_pass, HostRuntime, RuntimeConfig, RuntimeError,
};

struct PumpTasks {
    video: JoinHandle<()>,
    agents: JoinHandle<()>,
    pointer: JoinHandle<()>,
    audio: JoinHandle<()>,
    focus: JoinHandle<()>,
}

impl HostRuntime {
    /// Starts the video pump and the command loop on the current local task set. `run` does this; tests call it directly.
    pub fn start_pump(&self) {
        self.spawn_pumps();
    }

    fn spawn_pumps(&self) -> PumpTasks {
        let meter = supervise::PassMeter::new();
        let published = lock_ignoring_poison(&self.shared.control).published.clone();
        supervise::spawn_hang_monitor(&meter, published);
        PumpTasks {
            video: video_pass::spawn_pump(self.shared.clone(), self.profile.clone(), meter),
            agents: agent_pump::spawn_pump(self.shared.clone(), self.profile.clone()),
            pointer: pointer_pump::spawn_pump(self.shared.clone(), self.profile.clone()),
            audio: audio::spawn_pump(self.shared.clone(), self.profile.clone()),
            focus: focus_pump::spawn_pump(self.shared.clone(), self.profile.clone()),
        }
    }

    /// Runs the host until the process ends: binds the port, announces the host, and serves the relay and the pump.
    pub fn run(self, config: RuntimeConfig, identity: HostIdentity) -> Result<(), RuntimeError> {
        let executor = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(RuntimeError::Executor)?;
        let local = LocalSet::new();
        local.block_on(&executor, self.run_tasks(config, identity))
    }

    async fn run_tasks(self, config: RuntimeConfig, identity: HostIdentity) -> Result<(), RuntimeError> {
        let tls = Arc::new(HostTls::new(&identity).map_err(|error| RuntimeError::Tls(error.to_string()))?);
        let listener = TcpListener::bind(("0.0.0.0", config.port))
            .await
            .map_err(|source| RuntimeError::Bind { port: config.port, source })?;
        let _advertisement = advertise::start(identity.device_id(), &self.profile.host_name, config.port)?;
        let pumps = self.spawn_pumps();
        let (source, version) = {
            let state = self.shared.lock();
            (state.update_source.clone(), state.running_version)
        };
        update::spawn(self.shared.clone(), self.profile.clone(), source, version);
        if let Some(relay_config) = config.relay {
            relay_switch::spawn(self.shared.clone(), self.profile.clone(), tls.clone(), relay_config, Rc::new(identity));
        }
        if let Some(files) = config.hook_files {
            self.start_hooks(files);
        }
        let serving = listener::serve_listener(self.shared.clone(), self.profile, tls, listener);
        tokio::select! {
            () = serving => Ok(()),
            stopped = watch_pumps(pumps) => Err(stopped),
        }
    }
}

/// Waits for a pump that should never end. A pump that ended leaves the host serving a frozen picture, so it ends the
/// host with the reason, which the window shows.
async fn watch_pumps(pumps: PumpTasks) -> RuntimeError {
    tokio::select! {
        outcome = pumps.video => RuntimeError::TaskStopped { task: "video and command loop", reason: task_end_text(&outcome) },
        outcome = pumps.agents => RuntimeError::TaskStopped { task: "agent output loop", reason: task_end_text(&outcome) },
        outcome = pumps.pointer => RuntimeError::TaskStopped { task: "pointer loop", reason: task_end_text(&outcome) },
        outcome = pumps.audio => RuntimeError::TaskStopped { task: "audio loop", reason: task_end_text(&outcome) },
        outcome = pumps.focus => RuntimeError::TaskStopped { task: "text focus loop", reason: task_end_text(&outcome) },
    }
}

pub(super) fn task_end_text(outcome: &Result<(), tokio::task::JoinError>) -> String {
    match outcome {
        Ok(()) => "it returned".to_owned(),
        Err(error) if error.is_panic() => "it panicked".to_owned(),
        Err(error) => error.to_string(),
    }
}
