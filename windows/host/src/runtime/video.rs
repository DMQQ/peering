//! The video pump: capture and encode for the attached clients, each output handed to every client's lane, and the
//! display catalogue refreshed as displays change.

use std::sync::Arc;
use std::time::Duration;

use peering_core::ports::input::TransformSnapshot;
use peering_core::ports::system::SystemActions;
use peering_core::ports::capture::DisplayInfo;
use peering_core::session::dispatch::SourceControl;
use peering_core::video::coordinator::{CoordinatorError, VideoCoordinator};
use peering_core::video::lane::LaneSend;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::source::CaptureCatalog;
use peering_wire::source::CaptureSource;
use tokio::sync::mpsc::UnboundedSender;
use std::sync::PoisonError;
use tokio::task::spawn_local;
use tokio::time::interval;

use peering_core::notice::notice_frame;

use super::ready::error_frame;
use super::services::{BoxedEncoder, SharedCapture};
use super::control::{publish_if_due, take_commands};
use super::shared::{HostState, Shared};
use super::HostProfile;

const PUMP_INTERVAL: Duration = Duration::from_millis(16);
const CATALOGUE_CHECK_SECONDS: f64 = 1.0;
const NOTICE_CHECK_SECONDS: f64 = 0.5;
const NO_FRAMES_MESSAGE: &str = "The screen capture produced no frames.";

/// A frame bound for one connection, sent after the state lock is released.
pub struct Outgoing {
    pub to: UnboundedSender<Frame>,
    pub frame: Frame,
}

/// The dispatcher's view of the video coordinator and the workstation. A failure is kept for the caller to report.
pub struct CoordinatorControl<'a> {
    video: &'a mut VideoCoordinator<SharedCapture, BoxedEncoder>,
    system: &'a mut dyn SystemActions,
    now: f64,
    pub failure: Option<String>,
}

impl<'a> CoordinatorControl<'a> {
    pub fn new(
        video: &'a mut VideoCoordinator<SharedCapture, BoxedEncoder>,
        system: &'a mut dyn SystemActions,
        now: f64,
    ) -> Self {
        Self { video, system, now, failure: None }
    }
}

impl SourceControl for CoordinatorControl<'_> {
    fn set_source(&mut self, source: CaptureSource) {
        if let Err(error) = self.video.set_source(source, self.now) {
            self.failure.get_or_insert_with(|| error.to_string());
        }
    }

    fn set_quality(&mut self, fps: Option<u32>, bitrate_kbps: Option<u32>) {
        if let Some(fps) = fps {
            self.video.set_frame_rate(fps);
        }
        if let Some(kbps) = bitrate_kbps {
            self.video.set_quality(i64::from(kbps));
        }
    }

    fn set_video_enabled(&mut self, enabled: bool) {
        self.video.set_video_enabled(enabled);
    }

    fn lock_screen(&mut self) {
        if let Err(error) = self.system.lock_workstation() {
            self.failure.get_or_insert_with(|| error.to_string());
        }
    }
}

/// The transform a remote pointer is mapped through: the captured display, else the primary, else the first.
pub fn transform_for(displays: &[DisplayInfo], source: Option<&CaptureSource>) -> TransformSnapshot {
    let captured = match source {
        Some(CaptureSource::Display { id }) => displays.iter().find(|display| display.id == *id),
        _ => None,
    };
    let chosen = captured.or_else(|| displays.iter().find(|display| display.is_primary)).or_else(|| displays.first());
    match chosen {
        Some(display) => TransformSnapshot {
            origin_x: display.origin_x,
            origin_y: display.origin_y,
            pixel_width: display.pixel_width,
            pixel_height: display.pixel_height,
            scale: display.scale,
        },
        None => TransformSnapshot { origin_x: 0, origin_y: 0, pixel_width: 1, pixel_height: 1, scale: 1.0 },
    }
}

pub fn catalogue_frame(catalog: &CaptureCatalog) -> Frame {
    Frame::new(MessageKind::Catalog, serde_json::to_vec(catalog).expect("a catalogue always serialises"))
}

impl HostState {
    /// Refreshes the catalogue from the displays now attached and returns the frames due for `session`.
    pub fn catalogue_frames_for(&mut self, session: u64) -> Vec<Frame> {
        let displays = self.capture.displays();
        self.catalogue.update(&displays);
        let Some(catalog) = self.catalogue.current().cloned() else {
            return Vec::new();
        };
        self.catalogues.due(&session, &catalog).iter().map(catalogue_frame).collect()
    }

    pub fn active_transform(&self) -> TransformSnapshot {
        let displays = self.capture.displays();
        transform_for(&displays, self.video.running_source())
    }

    /// The notice frames due now: a change in what keeps the screen from being captured, and the report of a capture that
    /// never produced a frame. A standing notice already explains an empty picture, so it suppresses that report.
    fn session_notices(&mut self, now: f64) -> Vec<Outgoing> {
        let mut frames = Vec::new();
        if self.notice_checked_at.is_none_or(|checked| now - checked >= NOTICE_CHECK_SECONDS) {
            self.notice_checked_at = Some(now);
            if let Some(payload) = self.notices.update(self.system.session_notice()) {
                frames.push(notice_frame(&payload));
            }
        }
        if self.notices.standing().is_none() && self.video.take_watchdog_report(now) {
            frames.push(error_frame("sourceUnavailable", NO_FRAMES_MESSAGE));
        }
        let mut outgoing = Vec::new();
        for frame in frames {
            outgoing.extend(self.sessions.values().map(|slot| Outgoing { to: slot.outbound.clone(), frame: frame.clone() }));
        }
        outgoing
    }

    /// One pass of the pump: refresh the catalogue when due, capture and encode, and route each output to the lanes.
    pub fn pump_video(&mut self, now: f64) -> Result<Vec<Outgoing>, CoordinatorError> {
        let mut outgoing = Vec::new();
        if self.catalog_checked_at.is_none_or(|checked| now - checked >= CATALOGUE_CHECK_SECONDS) {
            self.catalog_checked_at = Some(now);
            let ids: Vec<u64> = self.sessions.keys().copied().collect();
            for session in ids {
                for frame in self.catalogue_frames_for(session) {
                    if let Some(slot) = self.sessions.get(&session) {
                        outgoing.push(Outgoing { to: slot.outbound.clone(), frame });
                    }
                }
            }
        }
        outgoing.extend(self.session_notices(now));
        for output in self.video.pump(now)? {
            for slot in self.sessions.values_mut() {
                let Ok(sends) = slot.lane.send(&output, now) else {
                    // The next keyframe resynchronises a client whose lane could not take this output.
                    continue;
                };
                let to = slot.video_outbound.clone().unwrap_or_else(|| slot.outbound.clone());
                for send in sends {
                    match send {
                        LaneSend::ControlFrames(frames) => {
                            outgoing.extend(frames.into_iter().map(|frame| Outgoing { to: to.clone(), frame }));
                        }
                        LaneSend::Datagram(bytes) => {
                            // Only a session with a relayed lane is granted a key, so its lane task is there to send it.
                            if let Some(datagrams) = &slot.datagram_outbound {
                                let _queued = datagrams.send(bytes);
                            }
                        }
                    }
                }
            }
        }
        Ok(outgoing)
    }
}

/// Runs the pump on a timer for the life of the host. Each pass first applies the UI's commands and publishes the
/// snapshot, so the window sees what the pump sees.
pub async fn run_pump(shared: Shared, profile: Arc<HostProfile>) {
    let mut ticks = interval(PUMP_INTERVAL);
    loop {
        ticks.tick().await;
        let now = profile.clock.now_seconds();
        let commands = take_commands(&mut shared.control.lock().unwrap_or_else(PoisonError::into_inner));
        let (decisions, outgoing) = {
            let mut state = shared.lock();
            let decisions = state.apply_commands(commands);
            publish_if_due(&state, &profile.host_id, &mut shared.control.lock().unwrap_or_else(PoisonError::into_inner), now);
            (decisions, state.pump_video(now))
        };
        for decision in decisions {
            // No waiting session means the client already left, so the decision has nothing to reach.
            let _delivered = shared.approvals.send(decision);
        }
        // A failed pass is retried on the next tick. Until one succeeds the client sees no new picture.
        if let Ok(outgoing) = outgoing {
            deliver(outgoing);
        }
        let terminal_output = shared.lock().pump_terminals();
        deliver(terminal_output);
    }
}

pub fn deliver(outgoing: Vec<Outgoing>) {
    for item in outgoing {
        // A connection whose writer has stopped ends on its own; a frame for it is dropped.
        let _queued = item.to.send(item.frame);
    }
}

pub fn spawn_pump(shared: Shared, profile: Arc<HostProfile>) {
    spawn_local(run_pump(shared, profile));
}
