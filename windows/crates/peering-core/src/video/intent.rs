//! Changes to the video coordinator that can wait. While a capture and encode is in flight the coordinator is out on the
//! encoding thread, so a phone registering or asking for another display records what it wants here, and the pass applies
//! it when it finishes. The connection task is never blocked behind the encode.

use std::collections::BTreeSet;

use peering_wire::source::CaptureSource;

use super::coordinator::{CoordinatorError, VideoCoordinator};
use crate::ports::capture::Capture;
use crate::ports::encoder::Encoder;

#[derive(Debug, Clone, PartialEq)]
pub enum VideoIntent {
    Attach(String),
    Detach(String),
    EnsureCapturing,
    SetSource(CaptureSource),
    StopWhenIdle,
    SetFrameRate(u32),
    SetQuality(i64),
    SetBitrateCeiling(Option<u32>),
    SetVideoEnabled(bool),
    SetWatched(bool),
    Resync,
    ResetAfterPanic,
}

impl VideoIntent {
    pub fn apply<C: Capture, E: Encoder>(&self, coordinator: &mut VideoCoordinator<C, E>, now: f64) -> Result<(), CoordinatorError> {
        match self {
            Self::Attach(client) => coordinator.attach(client),
            Self::Detach(client) => coordinator.detach(client),
            Self::EnsureCapturing => return coordinator.ensure_capturing(now),
            Self::SetSource(source) => return coordinator.set_source(source.clone(), now),
            Self::StopWhenIdle => coordinator.stop_when_idle(),
            Self::SetFrameRate(fps) => coordinator.set_frame_rate(*fps),
            Self::SetQuality(kbps) => coordinator.set_quality(*kbps),
            Self::SetBitrateCeiling(ceiling) => coordinator.set_bitrate_ceiling(*ceiling),
            Self::SetVideoEnabled(enabled) => coordinator.set_video_enabled(*enabled),
            Self::SetWatched(watched) => coordinator.set_watched(*watched),
            Self::Resync => coordinator.request_resync(),
            Self::ResetAfterPanic => coordinator.reset_after_panic(now),
        }
        Ok(())
    }

    /// Whether a later intent of the same kind makes this one pointless.
    fn replaced_by_later(&self) -> bool {
        matches!(
            self,
            Self::SetSource(_)
                | Self::SetFrameRate(_)
                | Self::SetQuality(_)
                | Self::SetBitrateCeiling(_)
                | Self::SetVideoEnabled(_)
                | Self::SetWatched(_)
                | Self::Resync
                | Self::ResetAfterPanic
        )
    }
}

/// What was asked while the coordinator was busy, in order. A setting asked for twice keeps only the later value.
#[derive(Debug, Default)]
pub struct IntentQueue {
    pending: Vec<VideoIntent>,
}

impl IntentQueue {
    pub fn push(&mut self, intent: VideoIntent) {
        if intent.replaced_by_later() {
            self.pending.retain(|earlier| std::mem::discriminant(earlier) != std::mem::discriminant(&intent));
        }
        self.pending.push(intent);
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    pub fn take(&mut self) -> Vec<VideoIntent> {
        std::mem::take(&mut self.pending)
    }
}

/// What the coordinator has been asked to be, kept outside it so a fresh coordinator can be given the same job when the
/// old one is lost with a thread that never came back.
#[derive(Debug)]
pub struct VideoDesired {
    clients: BTreeSet<String>,
    source: Option<CaptureSource>,
    frame_rate: Option<u32>,
    quality_kbps: Option<i64>,
    ceiling_kbps: Option<u32>,
    video_enabled: bool,
    watched: bool,
}

impl Default for VideoDesired {
    fn default() -> Self {
        Self { clients: BTreeSet::new(), source: None, frame_rate: None, quality_kbps: None, ceiling_kbps: None, video_enabled: true, watched: true }
    }
}

impl VideoDesired {
    pub fn note(&mut self, intent: &VideoIntent) {
        match intent {
            VideoIntent::Attach(client) => {
                self.clients.insert(client.clone());
            }
            VideoIntent::Detach(client) => {
                self.clients.remove(client);
            }
            VideoIntent::StopWhenIdle => {
                if self.clients.is_empty() {
                    self.source = None;
                }
            }
            VideoIntent::SetSource(source) => self.source = Some(source.clone()),
            VideoIntent::SetFrameRate(fps) => self.frame_rate = Some(*fps),
            VideoIntent::SetQuality(kbps) => self.quality_kbps = Some(*kbps),
            VideoIntent::SetBitrateCeiling(ceiling) => self.ceiling_kbps = *ceiling,
            VideoIntent::SetVideoEnabled(enabled) => self.video_enabled = *enabled,
            VideoIntent::SetWatched(watched) => self.watched = *watched,
            VideoIntent::EnsureCapturing | VideoIntent::Resync | VideoIntent::ResetAfterPanic => {}
        }
    }

    /// Gives a fresh coordinator the clients, settings and display this one describes, and starts capturing when anyone
    /// is attached.
    pub fn restore<C: Capture, E: Encoder>(&self, coordinator: &mut VideoCoordinator<C, E>, now: f64) -> Result<(), CoordinatorError> {
        for client in &self.clients {
            coordinator.attach(client);
        }
        if let Some(fps) = self.frame_rate {
            coordinator.set_frame_rate(fps);
        }
        if let Some(kbps) = self.quality_kbps {
            coordinator.set_quality(kbps);
        }
        coordinator.set_bitrate_ceiling(self.ceiling_kbps);
        coordinator.set_video_enabled(self.video_enabled);
        coordinator.set_watched(self.watched);
        if self.clients.is_empty() {
            return Ok(());
        }
        match &self.source {
            Some(source) => coordinator.set_source(source.clone(), now),
            None => coordinator.ensure_capturing(now),
        }
    }
}

#[cfg(test)]
mod tests;
