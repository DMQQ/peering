//! Keeps the relay's long-running tasks watched, and says whether they are all still running.
//!
//! A listener task that panics used to die alone: the process stayed up, `/healthz` kept
//! answering from the web listener, and nothing restarted it. Every task started here is expected
//! to run for the life of the process, so any exit is a failure and the caller shuts down so that
//! systemd starts a fresh process.

use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use tokio::task::{Id, JoinSet};

/// Which supervised tasks are alive, read by `/healthz`.
#[derive(Default)]
pub struct Health {
    components: Mutex<Vec<(&'static str, Arc<AtomicBool>)>>,
}

/// Marks its component dead when dropped, which includes unwinding from a panic.
pub struct Liveness(Arc<AtomicBool>);

impl Drop for Liveness {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

impl Health {
    pub fn track(&self, name: &'static str) -> Liveness {
        let alive = Arc::new(AtomicBool::new(true));
        self.components
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push((name, Arc::clone(&alive)));
        Liveness(alive)
    }

    pub fn failing(&self) -> Vec<&'static str> {
        self.components
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter(|(_, alive)| !alive.load(Ordering::SeqCst))
            .map(|(name, _)| *name)
            .collect()
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct Exit {
    pub name: &'static str,
    pub panicked: bool,
}

pub struct Supervisor {
    health: Arc<Health>,
    tasks: JoinSet<()>,
    names: HashMap<Id, &'static str>,
}

impl Supervisor {
    pub fn new(health: Arc<Health>) -> Self {
        Self { health, tasks: JoinSet::new(), names: HashMap::new() }
    }

    pub fn spawn(&mut self, name: &'static str, task: impl Future<Output = ()> + Send + 'static) {
        let live = self.health.track(name);
        let handle = self.tasks.spawn(async move {
            let _live = live;
            task.await;
        });
        self.names.insert(handle.id(), name);
    }

    /// Resolves when any task ends, or never when none were started.
    pub async fn next_exit(&mut self) -> Exit {
        let Some(finished) = self.tasks.join_next_with_id().await else {
            return std::future::pending().await;
        };
        let (id, panicked) = match finished {
            Ok((id, ())) => (id, false),
            Err(error) => (error.id(), error.is_panic()),
        };
        Exit { name: self.names.remove(&id).unwrap_or("unknown"), panicked }
    }
}

/// Resolves on ctrl-c or, where there is one, SIGTERM, which is what `systemctl stop` sends.
pub async fn shutdown_requested() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        match signal(SignalKind::terminate()) {
            Ok(mut terminate) => {
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {}
                    _ = terminate.recv() => {}
                }
                return;
            }
            Err(error) => tracing::warn!(%error, "could not listen for SIGTERM; only ctrl-c will stop the relay cleanly"),
        }
    }
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn a_panicking_task_is_reported_by_name_and_marks_health_failing() {
        let health = Arc::new(Health::default());
        let mut supervisor = Supervisor::new(Arc::clone(&health));
        supervisor.spawn("steady", std::future::pending());
        supervisor.spawn("control", async { panic!("boom") });

        let exit = tokio::time::timeout(Duration::from_secs(2), supervisor.next_exit())
            .await
            .expect("the panic should be noticed");
        assert_eq!(exit, Exit { name: "control", panicked: true });
        assert_eq!(health.failing(), vec!["control"]);
    }

    #[tokio::test]
    async fn a_task_that_returns_is_a_failure_too() {
        let health = Arc::new(Health::default());
        let mut supervisor = Supervisor::new(Arc::clone(&health));
        supervisor.spawn("sweep", async {});

        let exit = tokio::time::timeout(Duration::from_secs(2), supervisor.next_exit()).await.unwrap();
        assert_eq!(exit, Exit { name: "sweep", panicked: false });
        assert_eq!(health.failing(), vec!["sweep"]);
    }

    #[tokio::test]
    async fn health_is_clean_while_every_task_runs() {
        let health = Arc::new(Health::default());
        let mut supervisor = Supervisor::new(Arc::clone(&health));
        supervisor.spawn("udp", std::future::pending());
        assert!(health.failing().is_empty());
        let waited = tokio::time::timeout(Duration::from_millis(50), supervisor.next_exit()).await;
        assert!(waited.is_err(), "nothing has exited");
    }
}
