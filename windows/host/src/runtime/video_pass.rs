//! One pass of the video pump. The state lock is held to take the inputs and again to publish the result, and not across the
//! capture and encode between them, which can be slow: connections, handshakes and input keep running meanwhile.

use std::any::Any;
use std::collections::HashSet;
use std::panic::{catch_unwind, resume_unwind, AssertUnwindSafe};
use std::sync::Arc;
use std::time::Duration;

use peering_core::catalogue::SessionCatalogue;
use peering_core::pairing::ApprovalDecision;
use peering_core::supervision::ABANDON_PASS_SECONDS;
use peering_core::video::coordinator::{CoordinatorError, VideoOutput};
use peering_core::video::recovery::LogGate;
use tokio::task::{spawn_blocking, spawn_local, JoinError, JoinHandle};
use tokio::time::{interval, timeout, MissedTickBehavior};

use super::control::{publish, take_commands};
use super::diagnostics;
use super::lock::lock_ignoring_poison;
use super::problem_source::ProblemSource;
use super::shared::{HostState, Shared};
use super::supervise::{record_problem, Pass, PassMeter, Supervised};
use super::video::{deliver, queue_sends, Outgoing};
use super::video_handle::{PumpOutcome, VideoHandle};
use super::HostProfile;

const PUMP_INTERVAL: Duration = Duration::from_millis(16);

/// What the first step of a pass took under the state lock, carried to the last.
pub(super) struct Prepared {
    outgoing: Vec<Outgoing>,
    sessions: HashSet<u64>,
    pub(super) video: VideoHandle,
}

/// What a finished pass hands to the loop that ran it, to deliver after every lock is released.
pub(super) struct VideoPass {
    pub(super) decisions: Vec<ApprovalDecision>,
    pub(super) outgoing: Vec<Outgoing>,
    pub(super) failure: Option<CoordinatorError>,
}

impl HostState {
    /// The first step: what is due before the capture runs. Sessions that attach while the encode is in flight are left out
    /// of its result, because the keyframe they asked for comes with the next pass.
    pub(super) fn begin_video_pass(&mut self, now: f64) -> Prepared {
        self.release_silent_input(now);
        let mut outgoing = self.catalogue_frames_due(now);
        outgoing.extend(self.session_notices(now));
        self.resync_if_video_was_dropped();
        self.refresh_watched();
        Prepared { outgoing, sessions: self.sessions.keys().copied().collect(), video: self.video.clone() }
    }

    /// The last step: records the failure or the recovery and routes each output to the lanes of the sessions that were
    /// attached at the start. What was ready before the capture is kept when the capture or encoder failed.
    pub(super) fn finish_video_pass(
        &mut self,
        prepared: Prepared,
        outputs: Result<Vec<VideoOutput>, CoordinatorError>,
        now: f64,
    ) -> (Vec<Outgoing>, Option<CoordinatorError>) {
        let Prepared { mut outgoing, sessions, video } = prepared;
        let outputs = match outputs {
            Ok(outputs) => outputs,
            Err(error) => {
                self.set_problem(ProblemSource::Video, crate::strings::capture_recovering(&error.to_string()));
                return (outgoing, Some(error));
            }
        };
        if video.recovery_failures() == 0 {
            self.clear_problem(ProblemSource::Video);
        }
        for output in &outputs {
            self.route(output, &sessions, now, &mut outgoing);
        }
        (outgoing, None)
    }

    fn route(&mut self, output: &VideoOutput, sessions: &HashSet<u64>, now: f64, outgoing: &mut Vec<Outgoing>) {
        let attached = self.sessions.iter_mut().filter(|(id, slot)| sessions.contains(id) && !slot.background);
        for (_, slot) in attached {
            let Ok(sends) = slot.lane.send(output, now) else {
                // The next keyframe resynchronises a client whose lane could not take this output.
                continue;
            };
            queue_sends(slot, sends, outgoing);
        }
    }
}

/// One pass on the calling thread, for tests and callers that have no executor to hand the capture to.
pub(super) fn pump_video_inline(shared: &Shared, now: f64) -> Result<Vec<Outgoing>, CoordinatorError> {
    let prepared = shared.lock().begin_video_pass(now);
    let outputs = prepared.video.pump(now).unwrap_or_else(|payload| resume_unwind(payload));
    match shared.lock().finish_video_pass(prepared, outputs, now) {
        (outgoing, None) => Ok(outgoing),
        (_, Some(error)) => Err(error),
    }
}

/// One pass with the capture and encode on a blocking thread. Each step runs under `catch_unwind`, so a panic in any of
/// them comes back as the payload for the supervisor.
async fn run_video_pass(shared: &Shared, profile: &HostProfile, now: f64) -> std::thread::Result<VideoPass> {
    let (decisions, prepared) = catch_unwind(AssertUnwindSafe(|| {
        let (commands, publish_slot) = {
            let mut control = lock_ignoring_poison(&shared.control);
            (take_commands(&mut control), control.publish_due(now))
        };
        let mut state = shared.lock();
        let decisions = state.apply_commands(commands);
        let snapshot = publish_slot.as_ref().map(|_| state.snapshot(&profile.host_id));
        let prepared = state.begin_video_pass(now);
        drop(state);
        if let (Some(slot), Some(snapshot)) = (publish_slot, snapshot) {
            publish(&slot, snapshot);
        }
        (decisions, prepared)
    }))?;
    let outputs = match await_worker(&prepared.video, profile, now).await? {
        Worker::Returned(pumped) => pumped?,
        Worker::Overdue => {
            let outgoing = catch_unwind(AssertUnwindSafe(|| shared.lock().abandon_video_pass(prepared, now)))?;
            return Ok(VideoPass { decisions, outgoing, failure: None });
        }
    };
    let (outgoing, failure) = catch_unwind(AssertUnwindSafe(|| shared.lock().finish_video_pass(prepared, outputs, now)))?;
    Ok(VideoPass { decisions, outgoing, failure })
}

/// What became of the encoding thread.
enum Worker {
    Returned(PumpOutcome),
    Overdue,
}

/// Waits for the pass on the encoding thread, and gives up on it once it is past its deadline by the host's clock. The
/// thread is left to finish by itself; the handle has already moved on without what it holds.
async fn await_worker(video: &VideoHandle, profile: &HostProfile, now: f64) -> std::thread::Result<Worker> {
    let pumping = video.clone();
    let mut worker = spawn_blocking(move || pumping.pump(now));
    loop {
        match timeout(PUMP_INTERVAL, &mut worker).await {
            Ok(joined) => return joined.map(Worker::Returned).map_err(worker_payload),
            Err(_) if video.pass_overdue(profile.clock.now_seconds()) => return Ok(Worker::Overdue),
            Err(_) => {}
        }
    }
}

impl HostState {
    /// The pass never came back: its coordinator, capture and encoder are dropped for new ones, every phone is sent the
    /// catalogue again, and the window shows why the picture stopped. What was ready before the capture is still sent.
    fn abandon_video_pass(&mut self, prepared: Prepared, now: f64) -> Vec<Outgoing> {
        self.catalog_checked_at = None;
        self.notice_checked_at = None;
        self.catalogues = SessionCatalogue::new();
        if let Err(error) = self.video.abandon_pass(now) {
            diagnostics::log(&format!("the replacement capture could not start: {error}"));
        }
        self.set_problem(ProblemSource::Video, crate::strings::video_abandoned(ABANDON_PASS_SECONDS));
        diagnostics::log("a video pass did not return in time and was abandoned; its capture and encoder were replaced");
        prepared.outgoing
    }
}

fn worker_payload(error: JoinError) -> Box<dyn Any + Send> {
    if error.is_panic() {
        error.into_panic()
    } else {
        Box::new("the video worker was cancelled")
    }
}

/// Runs the pump on a timer for the life of the host. Each pass first applies the UI's commands and publishes the
/// snapshot, so the window sees what the pump sees. The video and terminal passes are supervised separately, so a panic
/// in one does not stop the other.
pub async fn run_pump(shared: Shared, profile: Arc<HostProfile>, meter: Arc<PassMeter>) {
    let mut ticks = interval(PUMP_INTERVAL);
    ticks.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut video = Supervised::new("video");
    let mut terminals = Supervised::new("terminals");
    let mut failures = LogGate::default();
    loop {
        ticks.tick().await;
        let now = profile.clock.now_seconds();
        meter.begin();
        if video.ready(now) {
            let outcome = run_video_pass(&shared, &profile, now).await;
            let pass = video.settle(now, outcome, |text| record_problem(&shared, ProblemSource::Video, text));
            match pass {
                Pass::Done(finished) => deliver_pass(&shared, finished, &mut failures, now),
                Pass::Panicked => shared.lock().reset_after_video_panic(),
                Pass::Skipped => {}
            }
        }
        let terminal_pass = terminals.run(now, || shared.lock().pump_terminals(), |text| record_problem(&shared, ProblemSource::Terminals, text));
        if let Pass::Done(terminal_output) = terminal_pass {
            deliver(terminal_output);
        }
        meter.end();
    }
}

fn deliver_pass(shared: &Shared, finished: VideoPass, failures: &mut LogGate, now: f64) {
    for decision in finished.decisions {
        // No waiting session means the client already left, so the decision has nothing to reach.
        let _delivered = shared.approvals.send(decision);
    }
    deliver(finished.outgoing);
    if let (Some(failure), Some(held_back)) = (finished.failure, failures.allow(now)) {
        diagnostics::log(&format!("the video pump failed: {failure} ({held_back} more held back)"));
    }
}

pub fn spawn_pump(shared: Shared, profile: Arc<HostProfile>, meter: Arc<PassMeter>) -> JoinHandle<()> {
    spawn_local(run_pump(shared, profile, meter))
}
