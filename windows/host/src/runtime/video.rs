//! What the video pump sends besides pictures: the dispatcher's view of the coordinator, the display catalogue as displays
//! change, and the notices about what keeps the screen from being captured.

use peering_core::notice::notice_frame;
use peering_core::ports::capture::DisplayInfo;
use peering_core::ports::input::TransformSnapshot;
use peering_core::ports::system::SystemActions;
use peering_core::session::dispatch::SourceControl;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::source::{CaptureCatalog, CaptureSource};

use super::outbound::FrameSender;
use super::ready::error_frame;
use super::shared::HostState;
use super::video_handle::VideoHandle;

const CATALOGUE_CHECK_SECONDS: f64 = 1.0;
const NOTICE_CHECK_SECONDS: f64 = 0.5;
const NO_FRAMES_MESSAGE: &str = "The screen capture produced no frames.";
const RECOVERING_MESSAGE: &str = "The screen capture stopped and the host is restarting it.";

/// A frame bound for one connection, sent after the state lock is released.
pub struct Outgoing {
    pub to: FrameSender,
    pub frame: Frame,
}

/// The dispatcher's view of the video coordinator and the workstation. A failure is kept for the caller to report.
pub struct CoordinatorControl<'a> {
    video: &'a VideoHandle,
    system: &'a mut dyn SystemActions,
    now: f64,
    pub failure: Option<String>,
}

impl<'a> CoordinatorControl<'a> {
    pub fn new(video: &'a VideoHandle, system: &'a mut dyn SystemActions, now: f64) -> Self {
        Self { video, system, now, failure: None }
    }
}

impl SourceControl for CoordinatorControl<'_> {
    fn set_source(&mut self, source: CaptureSource) {
        if let Err(error) = self.video.lock().set_source(source, self.now) {
            self.failure.get_or_insert_with(|| error.to_string());
        }
    }

    fn set_quality(&mut self, fps: Option<u32>, bitrate_kbps: Option<u32>) {
        let mut video = self.video.lock();
        if let Some(fps) = fps {
            video.set_frame_rate(fps);
        }
        if let Some(kbps) = bitrate_kbps {
            video.set_quality(i64::from(kbps));
        }
    }

    fn set_video_enabled(&mut self, enabled: bool) {
        self.video.lock().set_video_enabled(enabled);
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

    /// The catalogue frames due now, one batch per attached session, when the check interval has passed.
    pub(super) fn catalogue_frames_due(&mut self, now: f64) -> Vec<Outgoing> {
        if self.catalog_checked_at.is_some_and(|checked| now - checked < CATALOGUE_CHECK_SECONDS) {
            return Vec::new();
        }
        self.catalog_checked_at = Some(now);
        let mut outgoing = Vec::new();
        let ids: Vec<u64> = self.sessions.keys().copied().collect();
        for session in ids {
            for frame in self.catalogue_frames_for(session) {
                if let Some(slot) = self.sessions.get(&session) {
                    outgoing.push(Outgoing { to: slot.outbound.clone(), frame });
                }
            }
        }
        outgoing
    }

    pub fn active_transform(&self) -> TransformSnapshot {
        let displays = self.capture.displays();
        transform_for(&displays, self.video.running_source().as_ref())
    }

    /// The notice frames due now: a change in what keeps the screen from being captured, and the report of a capture that
    /// never produced a frame. A standing notice already explains an empty picture, so it suppresses that report.
    pub(super) fn session_notices(&mut self, now: f64) -> Vec<Outgoing> {
        let mut frames = Vec::new();
        if self.notice_checked_at.is_none_or(|checked| now - checked >= NOTICE_CHECK_SECONDS) {
            self.notice_checked_at = Some(now);
            if let Some(payload) = self.notices.update(self.system.session_notice()) {
                frames.push(notice_frame(&payload));
            }
        }
        if self.notices.standing().is_none() {
            if self.video.lock().take_watchdog_report(now) {
                frames.push(error_frame("sourceUnavailable", NO_FRAMES_MESSAGE));
            } else if self.video.lock().take_recovery_report() {
                frames.push(error_frame("sourceUnavailable", RECOVERING_MESSAGE));
            }
        }
        let mut outgoing = Vec::new();
        for frame in frames {
            outgoing.extend(self.sessions.values().map(|slot| Outgoing { to: slot.outbound.clone(), frame: frame.clone() }));
        }
        outgoing
    }
}

pub fn deliver(outgoing: Vec<Outgoing>) {
    for item in outgoing {
        // A connection whose writer has stopped ends on its own; a frame for it is dropped.
        let _queued = item.to.send(item.frame);
    }
}
