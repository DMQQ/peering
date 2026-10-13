//! Tells the phones where the PC's keyboard focus is, so a phone that asked can raise its keyboard for a text field and show
//! what the field holds. The decisions are the core's `FocusWatcher`; this watches only while a phone that declared
//! `supportsTextFocus` or `supportsFieldState` is connected, as the Mac host does.

use std::sync::Arc;
use std::time::Duration;

use peering_core::focus::{FocusMessage, FocusWatcher};
use peering_core::ports::focus::FocusProbe;
use peering_core::ports::input::InputSink;
use peering_wire::framing::{Frame, MessageKind};
use tokio::task::{spawn_local, JoinHandle};
use tokio::time::interval;

use super::agent_pump::supervised_pass;
use super::problem_source::ProblemSource;
use super::shared::{HostState, Shared};
use super::supervise::Supervised;
use super::video::{deliver, Outgoing};
use super::HostProfile;

const POLL_INTERVAL: Duration = Duration::from_millis(100);

pub struct FocusPipeline {
    probe: Box<dyn FocusProbe + Send>,
    watcher: FocusWatcher,
    watching: bool,
    presses_seen: u64,
}

impl FocusPipeline {
    pub fn new(probe: Box<dyn FocusProbe + Send>) -> Self {
        Self { probe, watcher: FocusWatcher::default(), watching: false, presses_seen: 0 }
    }
}

impl HostState {
    /// One look at the focus. A `textFocus` goes to each phone that declared `supportsTextFocus` and a `fieldState` to each that
    /// declared `supportsFieldState`.
    pub fn pump_focus(&mut self) -> Vec<Outgoing> {
        let interested = |slot: &super::shared::SessionSlot| {
            slot.client_flags.supports_text_focus == Some(true) || slot.client_flags.supports_field_state == Some(true)
        };
        let wanted = self.hosting && self.sessions.values().any(interested);
        let presses = self.input.button_presses();
        if wanted != self.focus.watching {
            self.focus.watching = wanted;
            self.focus.probe.set_active(wanted);
            self.focus.watcher.reset();
            self.focus.presses_seen = presses;
        }
        if !wanted {
            return Vec::new();
        }
        if presses != self.focus.presses_seen {
            self.focus.presses_seen = presses;
            if let Some((x, y)) = self.input.pointer_position() {
                self.focus.probe.tapped_at(x as i32, y as i32);
            }
        }
        let transform = self.active_transform();
        let mut messages = Vec::new();
        for report in self.focus.probe.drain() {
            messages.extend(self.focus.watcher.on_report(&report, &transform));
        }
        self.focus_frames(&messages)
    }

    fn focus_frames(&self, messages: &[FocusMessage]) -> Vec<Outgoing> {
        let mut outgoing = Vec::new();
        for message in messages {
            // Derived Serialize over a bool, a string and numbers: no field can make the writer fail.
            let (kind, payload, wants): (_, _, fn(&super::shared::SessionSlot) -> bool) = match message {
                FocusMessage::Focus(focus) => (
                    MessageKind::TextFocus,
                    serde_json::to_vec(focus).expect("a text focus always serialises"),
                    |slot| slot.client_flags.supports_text_focus == Some(true),
                ),
                FocusMessage::Field(state) => (
                    MessageKind::FieldState,
                    serde_json::to_vec(state).expect("a field state always serialises"),
                    |slot| slot.client_flags.supports_field_state == Some(true),
                ),
            };
            let frame = Frame::new(kind, payload);
            outgoing.extend(
                self.sessions.values().filter(|slot| wants(slot)).map(|slot| Outgoing { to: slot.outbound.clone(), frame: frame.clone() }),
            );
        }
        outgoing
    }
}

async fn run(shared: Shared, profile: Arc<HostProfile>) {
    let mut ticks = interval(POLL_INTERVAL);
    let mut supervised = Supervised::new("text focus");
    loop {
        ticks.tick().await;
        let now = profile.clock.now_seconds();
        deliver(supervised_pass(&mut supervised, &shared, ProblemSource::Focus, now, HostState::pump_focus));
    }
}

pub fn spawn_pump(shared: Shared, profile: Arc<HostProfile>) -> JoinHandle<()> {
    spawn_local(run(shared, profile))
}

#[cfg(test)]
mod tests;
