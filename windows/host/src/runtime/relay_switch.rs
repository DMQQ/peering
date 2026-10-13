//! Starts and stops the relay connection with the `relayEnabled` setting, so the person can take the PC off the relay without
//! restarting the host. The registration itself is `relay::run`.

use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use peering_net::identity::HostIdentity;
use peering_net::tls::HostTls;
use peering_wire::relay_proof::ProofSigner;
use tokio::task::{spawn_local, JoinHandle};
use tokio::time::interval;

use super::control::RelayStatus;
use super::problem_source::ProblemSource;
use super::shared::Shared;
use super::{relay, HostProfile, RelayConfig};

const TICK: Duration = Duration::from_secs(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Off,
    Running,
    /// The relay task ended by itself. It stays ended until the setting is turned off and on again.
    Ended,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    Start,
    Stop,
    NoteEnded,
    Nothing,
}

/// What to do now, and the phase that follows.
fn step(phase: Phase, wanted: bool, task_finished: bool) -> (Phase, Step) {
    match (phase, wanted) {
        (Phase::Off, true) => (Phase::Running, Step::Start),
        (Phase::Running, true) if task_finished => (Phase::Ended, Step::NoteEnded),
        (Phase::Running, false) => (Phase::Off, Step::Stop),
        (Phase::Ended, false) => (Phase::Off, Step::Stop),
        (phase, _) => (phase, Step::Nothing),
    }
}

/// The identity, shared so a relay that is started again signs with the same key.
struct SharedIdentity(Rc<HostIdentity>);

impl ProofSigner for SharedIdentity {
    fn public_key(&self) -> Vec<u8> {
        ProofSigner::public_key(self.0.as_ref())
    }

    fn sign(&self, message: &[u8]) -> Vec<u8> {
        ProofSigner::sign(self.0.as_ref(), message)
    }
}

pub(super) fn spawn(
    shared: Shared,
    profile: Arc<HostProfile>,
    tls: Arc<HostTls>,
    config: RelayConfig,
    identity: Rc<HostIdentity>,
) -> JoinHandle<()> {
    spawn_local(async move {
        let mut ticks = interval(TICK);
        let mut phase = Phase::Off;
        let mut task: Option<JoinHandle<()>> = None;
        loop {
            ticks.tick().await;
            let wanted = shared.lock().settings.relay_enabled;
            let finished = task.as_ref().is_some_and(JoinHandle::is_finished);
            let (next, action) = step(phase, wanted, finished);
            phase = next;
            match action {
                Step::Start => {
                    let signer = Box::new(SharedIdentity(identity.clone()));
                    task = Some(spawn_local(relay::run(shared.clone(), profile.clone(), tls.clone(), config.clone(), signer)));
                }
                Step::Stop => {
                    if let Some(running) = task.take() {
                        running.abort();
                    }
                    shared.peer_addresses().attach(None);
                    let mut state = shared.lock();
                    state.relay = RelayStatus::Off;
                    state.clear_problem(ProblemSource::Relay);
                    state.clear_problem(ProblemSource::RelayClock);
                }
                Step::NoteEnded => {
                    let outcome = match task.take() {
                        Some(ended) => ended.await,
                        None => Ok(()),
                    };
                    let mut state = shared.lock();
                    state.relay = RelayStatus::Off;
                    state.set_problem(ProblemSource::Relay, crate::strings::relay_task_stopped(&super::serve::task_end_text(&outcome)));
                }
                Step::Nothing => {}
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turning_the_relay_on_starts_it_once() {
        assert_eq!(step(Phase::Off, true, false), (Phase::Running, Step::Start));
        assert_eq!(step(Phase::Running, true, false), (Phase::Running, Step::Nothing));
    }

    #[test]
    fn turning_the_relay_off_stops_it() {
        assert_eq!(step(Phase::Running, false, false), (Phase::Off, Step::Stop));
        assert_eq!(step(Phase::Off, false, false), (Phase::Off, Step::Nothing));
    }

    #[test]
    fn a_relay_that_ended_by_itself_is_reported_once_and_not_restarted() {
        assert_eq!(step(Phase::Running, true, true), (Phase::Ended, Step::NoteEnded));
        assert_eq!(step(Phase::Ended, true, true), (Phase::Ended, Step::Nothing));
    }

    #[test]
    fn turning_off_a_relay_that_ended_clears_its_problem_and_allows_a_fresh_start() {
        assert_eq!(step(Phase::Ended, false, true), (Phase::Off, Step::Stop));
        assert_eq!(step(Phase::Off, true, false), (Phase::Running, Step::Start));
    }

    #[test]
    fn a_relay_that_finishes_as_it_is_turned_off_is_simply_stopped() {
        assert_eq!(step(Phase::Running, false, true), (Phase::Off, Step::Stop));
    }
}
