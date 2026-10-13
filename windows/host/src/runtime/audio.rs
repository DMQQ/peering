//! Sends the sound the PC is playing to the phones that are looking at it. Listening starts when a phone is in the foreground
//! and stops when none is, as the Mac host's capture does. The conversion is `peering_core::audio`; this routes the frames
//! down each phone's video lane, so they take the same way (a second connection, the relayed UDP lane or the control
//! connection) as the picture.

use std::sync::Arc;
use std::time::Duration;

use peering_core::audio::{output_config, AudioConditioner};
use peering_core::ports::audio::AudioSource;
use peering_wire::video::EncodedAudioFrame;
use tokio::task::{spawn_local, JoinHandle};
use tokio::time::interval;

use super::agent_pump::supervised_pass;
use super::problem_source::ProblemSource;
use super::shared::{HostState, Shared};
use super::supervise::Supervised;
use super::video::{deliver, queue_sends, Outgoing};
use super::HostProfile;

const POLL_INTERVAL: Duration = Duration::from_millis(20);
/// Passes with nothing captured before the tail of a sound is sent: WASAPI delivers nothing at all while the PC is silent.
const QUIET_PASSES_BEFORE_FLUSH: u32 = 3;

/// The source of sound, and the state of converting it.
pub struct AudioPipeline {
    source: Box<dyn AudioSource + Send>,
    conditioner: AudioConditioner,
    listening: bool,
    quiet_passes: u32,
}

impl AudioPipeline {
    pub fn new(source: Box<dyn AudioSource + Send>) -> Self {
        Self { source, conditioner: AudioConditioner::new(), listening: false, quiet_passes: 0 }
    }

    /// Returns true when listening just stopped.
    fn listen(&mut self, wanted: bool) -> bool {
        if wanted == self.listening {
            return false;
        }
        self.listening = wanted;
        self.source.set_active(wanted);
        self.quiet_passes = 0;
        if !wanted {
            self.conditioner.reset();
        }
        !wanted
    }

    fn frames(&mut self) -> Vec<EncodedAudioFrame> {
        let packets = self.source.drain();
        if packets.is_empty() {
            self.quiet_passes = self.quiet_passes.saturating_add(1);
            return if self.quiet_passes == QUIET_PASSES_BEFORE_FLUSH { self.conditioner.flush().into_iter().collect() } else { Vec::new() };
        }
        self.quiet_passes = 0;
        packets.iter().flat_map(|packet| self.conditioner.push(packet)).collect()
    }
}

impl HostState {
    /// One look at the sound. The frames go to every phone that is in the foreground, each after the config it is owed.
    pub fn pump_audio(&mut self) -> Vec<Outgoing> {
        let wanted = self.hosting && self.sessions.values().any(|slot| !slot.background);
        if self.audio.listen(wanted) {
            for slot in self.sessions.values_mut() {
                slot.audio.pause();
            }
        }
        if !wanted {
            self.clear_problem(ProblemSource::Audio);
            return Vec::new();
        }
        match self.audio.source.failure() {
            Some(reason) => self.set_problem(ProblemSource::Audio, crate::strings::audio_unavailable(&reason)),
            None => self.clear_problem(ProblemSource::Audio),
        }
        let frames = self.audio.frames();
        if frames.is_empty() {
            return Vec::new();
        }
        let mut outgoing = Vec::new();
        for slot in self.sessions.values_mut().filter(|slot| !slot.background) {
            let mut sends = Vec::new();
            if slot.audio.config_due(slot.video_outbound.is_some()) {
                sends.extend(slot.lane.send_audio_config(&output_config()).unwrap_or_default());
            }
            for frame in &frames {
                // A frame the lane cannot carry is one frame of sound lost, which the next one replaces.
                sends.extend(slot.lane.send_audio(frame).unwrap_or_default());
            }
            queue_sends(slot, sends, &mut outgoing);
        }
        outgoing
    }
}

async fn run(shared: Shared, profile: Arc<HostProfile>) {
    let mut ticks = interval(POLL_INTERVAL);
    let mut supervised = Supervised::new("audio");
    loop {
        ticks.tick().await;
        let now = profile.clock.now_seconds();
        deliver(supervised_pass(&mut supervised, &shared, ProblemSource::Audio, now, HostState::pump_audio));
    }
}

pub fn spawn_pump(shared: Shared, profile: Arc<HostProfile>) -> JoinHandle<()> {
    spawn_local(run(shared, profile))
}

#[cfg(test)]
mod tests;
