//! What the video pump sends besides pictures: the dispatcher's view of the coordinator, the display catalogue as displays
//! change, and the notices about what keeps the screen from being captured.

use peering_core::notice::notice_frame;
use peering_core::video::coordinator::CaptureCondition;
use peering_core::video::intent::VideoIntent;
use peering_core::video::lane::LaneSend;
use peering_wire::handshake::NoticePayload;
use peering_core::ports::capture::{DisplayInfo, WindowInfo};
use peering_core::ports::input::TransformSnapshot;
use peering_core::ports::system::SystemActions;
use peering_core::session::dispatch::SourceControl;
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::source::{thumbnail_json, CaptureCatalog, CaptureSource};
use std::collections::HashSet;

use super::outbound::FrameSender;
use super::shared::{HostState, SessionSlot};
use super::video_handle::VideoHandle;

const CATALOGUE_CHECK_SECONDS: f64 = 1.0;
const NOTICE_CHECK_SECONDS: f64 = 0.5;
const CAPTURE_NOTICE_SYMBOL: &str = "exclamationmark.triangle.fill";
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
        if let Err(error) = self.video.apply(VideoIntent::SetSource(source), self.now) {
            self.failure.get_or_insert_with(|| error.to_string());
        }
    }

    fn set_quality(&mut self, fps: Option<u32>, bitrate_kbps: Option<u32>) {
        if let Some(fps) = fps {
            self.video.request(VideoIntent::SetFrameRate(fps));
        }
        if let Some(kbps) = bitrate_kbps {
            self.video.request(VideoIntent::SetQuality(i64::from(kbps)));
        }
    }

    fn set_video_enabled(&mut self, enabled: bool) {
        self.video.request(VideoIntent::SetVideoEnabled(enabled));
    }

    fn lock_screen(&mut self) {
        if let Err(error) = self.system.lock_workstation() {
            self.failure.get_or_insert_with(|| error.to_string());
        }
    }
}

/// The transform a remote pointer is mapped through: the captured window or display, else the primary display, else the first.
pub fn transform_for(displays: &[DisplayInfo], window: Option<&WindowInfo>, source: Option<&CaptureSource>) -> TransformSnapshot {
    if let (Some(CaptureSource::Window { .. }), Some(window)) = (source, window) {
        return TransformSnapshot {
            origin_x: window.origin_x,
            origin_y: window.origin_y,
            pixel_width: window.pixel_width,
            pixel_height: window.pixel_height,
            scale: window.scale,
        };
    }
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

fn capture_notice(condition: Option<CaptureCondition>) -> Option<NoticePayload> {
    let (message, code) = match condition? {
        CaptureCondition::NoFrames => (NO_FRAMES_MESSAGE, "captureNoFrames"),
        CaptureCondition::Recovering => (RECOVERING_MESSAGE, "captureRecovering"),
    };
    Some(NoticePayload {
        message: Some(message.to_owned()),
        symbol: Some(CAPTURE_NOTICE_SYMBOL.to_owned()),
        locked_display_id: None,
        code: Some(code.to_owned()),
    })
}

pub fn catalogue_frame(catalog: &CaptureCatalog) -> Frame {
    // A derived Serialize over strings and numbers: the display names come from the OS, and no field can make the writer fail.
    Frame::new(MessageKind::Catalog, serde_json::to_vec(catalog).expect("a catalogue always serialises"))
}

impl HostState {
    /// Refreshes the catalogue from the displays now attached and the windows that can be captured, and returns the frames due
    /// for `session`.
    pub fn catalogue_frames_for(&mut self, session: u64) -> Vec<Frame> {
        self.refresh_catalogue();
        self.catalogue_due(session)
    }

    /// Returns the sources the catalogue now lists, which are the ones to photograph.
    fn refresh_catalogue(&mut self) -> Vec<CaptureSource> {
        let displays = self.video.capture().displays();
        let windows = self.video.capture().windows();
        let sources = self.take_pictures(&displays, &windows);
        self.catalogue.update_with_windows(&displays, &windows);
        sources
    }

    /// Files the pictures a finished round took and drops those of sources that are gone.
    fn take_pictures(&mut self, displays: &[DisplayInfo], windows: &[WindowInfo]) -> Vec<CaptureSource> {
        let sources: Vec<CaptureSource> = displays
            .iter()
            .map(|display| CaptureSource::Display { id: display.id })
            .chain(windows.iter().map(|window| CaptureSource::Window { id: window.id }))
            .collect();
        let live: HashSet<String> = sources.iter().map(CaptureSource::stable_id).collect();
        self.catalogue.keep_pictures_of(&live);
        for (id, image) in self.pictures.take_landed() {
            if live.contains(&id) {
                self.catalogue.set_picture(&id, thumbnail_json(image.width, image.height, &image.jpeg));
            }
        }
        sources
    }

    fn catalogue_due(&mut self, session: u64) -> Vec<Frame> {
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
        let sources = self.refresh_catalogue();
        self.pictures.start_if_due(now, sources);
        let ids: Vec<u64> = self.sessions.keys().copied().collect();
        for session in ids {
            for frame in self.catalogue_due(session) {
                if let Some(slot) = self.sessions.get(&session) {
                    outgoing.push(Outgoing { to: slot.outbound.clone(), frame });
                }
            }
        }
        outgoing
    }

    pub fn active_transform(&self) -> TransformSnapshot {
        let displays = self.video.capture().displays();
        let source = self.video.running_source();
        let window = match &source {
            Some(CaptureSource::Window { id }) => self.video.capture().window(*id),
            _ => None,
        };
        transform_for(&displays, window.as_ref(), source.as_ref())
    }

    /// The notice frames due now: a change in what keeps the screen from being captured, else a standing report that the
    /// capture produced nothing or keeps failing, which ends with the first frame. What keeps the screen from being captured
    /// explains an empty picture, so it takes the place of that report.
    pub(super) fn session_notices(&mut self, now: f64) -> Vec<Outgoing> {
        if self.notice_checked_at.is_some_and(|checked| now - checked < NOTICE_CHECK_SECONDS) {
            return Vec::new();
        }
        self.notice_checked_at = Some(now);
        if self.refusal.as_ref().is_some_and(|refusal| !refusal.in_force(now)) {
            self.refusal = None;
        }
        let desired = self
            .system
            .session_notice()
            .or_else(|| capture_notice(self.video.capture_condition()))
            .or_else(|| self.refusal.as_ref().map(|refusal| refusal.notice.clone()));
        let Some(payload) = self.notices.update(desired) else {
            return Vec::new();
        };
        let frame = notice_frame(&payload);
        self.sessions.values().map(|slot| Outgoing { to: slot.outbound.clone(), frame: frame.clone() }).collect()
    }
}

/// Turns what a lane produced into the frames to write, onto the session's video connection when it has one.
pub fn queue_sends(slot: &SessionSlot, sends: Vec<LaneSend>, outgoing: &mut Vec<Outgoing>) {
    let to = slot.video_outbound.clone().unwrap_or_else(|| slot.outbound.clone());
    for send in sends {
        match send {
            LaneSend::ControlFrames(frames) => outgoing.extend(frames.into_iter().map(|frame| Outgoing { to: to.clone(), frame })),
            LaneSend::Datagram(bytes) => {
                // Only a session with a relayed lane is granted a key, so its lane task is there to send it.
                if let Some(datagrams) = &slot.datagram_outbound {
                    let _queued = datagrams.send(bytes);
                }
            }
        }
    }
}

pub fn deliver(outgoing: Vec<Outgoing>) {
    for item in outgoing {
        // A connection whose writer has stopped ends on its own; a frame for it is dropped.
        let _queued = item.to.send(item.frame);
    }
}
