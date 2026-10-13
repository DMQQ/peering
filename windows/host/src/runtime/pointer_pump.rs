//! Tells the phones where the PC's pointer is when a hand moved it, and where a joystick nudge left it. The decisions are the
//! core's `PointerTracker`; this watches the pointer a few times a second while a phone is connected.

use std::sync::Arc;
use std::time::Duration;

use peering_core::ports::input::InputSink;
use peering_core::pointer::PointerView;
use peering_wire::framing::{Frame, MessageKind};
use tokio::task::{spawn_local, JoinHandle};
use tokio::time::interval;

use super::agent_pump::supervised_pass;
use super::problem_source::ProblemSource;
use super::shared::{HostState, Shared};
use super::supervise::Supervised;
use super::video::{deliver, Outgoing};
use super::HostProfile;

const POLL_INTERVAL: Duration = Duration::from_millis(50);

impl HostState {
    /// One look at the pointer. The report goes to every phone that declared `supportsPointerReport`.
    pub fn pump_pointer(&mut self, now: f64) -> Vec<Outgoing> {
        if self.sessions.is_empty() {
            self.pointer.reset();
            return Vec::new();
        }
        let Some(cursor) = self.input.pointer_position() else {
            return Vec::new();
        };
        let view = PointerView {
            cursor,
            injected: self.input.last_injected_position(),
            nudges: self.input.joystick_nudges(),
            transform: self.active_transform(),
        };
        let Some(point) = self.pointer.look(now, &view) else {
            return Vec::new();
        };
        // A derived Serialize over two numbers.
        let frame = Frame::new(MessageKind::PointerReport, serde_json::to_vec(&point).expect("a point always serialises"));
        self.sessions
            .values()
            .filter(|slot| slot.client_flags.supports_pointer_report == Some(true))
            .map(|slot| Outgoing { to: slot.outbound.clone(), frame: frame.clone() })
            .collect()
    }
}

async fn run(shared: Shared, profile: Arc<HostProfile>) {
    let mut ticks = interval(POLL_INTERVAL);
    let mut supervised = Supervised::new("pointer");
    loop {
        ticks.tick().await;
        let now = profile.clock.now_seconds();
        deliver(supervised_pass(&mut supervised, &shared, ProblemSource::Pointer, now, |state| state.pump_pointer(now)));
    }
}

pub fn spawn_pump(shared: Shared, profile: Arc<HostProfile>) -> JoinHandle<()> {
    spawn_local(run(shared, profile))
}

#[cfg(test)]
mod tests {
    use super::super::test_support::{runtime, slot};

    #[test]
    fn with_no_phone_connected_nothing_is_watched() {
        let runtime = runtime();
        assert!(runtime.shared.lock().pump_pointer(1.0).is_empty());
    }

    #[test]
    fn a_stand_in_input_that_cannot_see_the_pointer_reports_nothing() {
        let runtime = runtime();
        let mut state = runtime.shared.lock();
        state.sessions.insert(1, slot("phone"));
        assert!(state.pump_pointer(1.0).is_empty());
    }
}
