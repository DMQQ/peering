//! Turning what the PC plays into what the phone is sent: `audioConfig` and `audioFrame`, raw interleaved little endian
//! Float32 at 48 kHz in two channels, as the Mac host sends it. The platform captures in whatever format the PC mixes in;
//! this layer converts and cuts it into frames. Nothing here touches the operating system.

mod delivery;
mod resample;
#[cfg(test)]
mod tests;

pub use delivery::AudioDelivery;
pub use resample::StereoResampler;

use peering_wire::video::{AudioCodec, AudioStreamConfig, EncodedAudioFrame, VideoTimestamp};

use crate::ports::audio::CapturedAudio;

pub const OUTPUT_RATE: u32 = 48_000;
pub const OUTPUT_CHANNELS: u32 = 2;
/// 20 ms, so a frame is 7.7 KB and always fits one piece on the control connection.
pub const FRAME_SAMPLES: usize = 960;
/// A bound that keeps a broken driver's values from travelling; the clients clip anything louder anyway.
const SAMPLE_LIMIT: f32 = 4.0;

pub fn output_config() -> AudioStreamConfig {
    AudioStreamConfig { codec: AudioCodec::PcmFloat32, sample_rate: f64::from(OUTPUT_RATE), channel_count: OUTPUT_CHANNELS }
}

/// Converts captured packets to frames of exactly `FRAME_SAMPLES` stereo samples at 48 kHz.
#[derive(Debug, Default)]
pub struct AudioConditioner {
    resampler: Option<StereoResampler>,
    waiting: Vec<f32>,
    emitted_samples: i64,
}

impl AudioConditioner {
    pub fn new() -> Self {
        Self::default()
    }

    /// The frames now complete. A packet in a different rate than the last starts a new resampler.
    pub fn push(&mut self, packet: &CapturedAudio) -> Vec<EncodedAudioFrame> {
        let stereo = to_stereo(&packet.samples, packet.channels);
        if stereo.is_empty() || packet.sample_rate == 0 {
            return Vec::new();
        }
        if self.resampler.as_ref().is_none_or(|resampler| resampler.from_rate() != packet.sample_rate) {
            self.resampler = Some(StereoResampler::new(packet.sample_rate, OUTPUT_RATE));
        }
        if let Some(resampler) = self.resampler.as_mut() {
            self.waiting.extend(resampler.process(&stereo));
        }
        self.cut_frames()
    }

    /// The sound went quiet: what is waiting, padded with silence to a whole frame, so the end of a sound is not lost.
    pub fn flush(&mut self) -> Option<EncodedAudioFrame> {
        if self.waiting.is_empty() {
            return None;
        }
        self.waiting.resize(FRAME_SAMPLES * 2, 0.0);
        let frames = self.cut_frames();
        self.resampler = None;
        frames.into_iter().next()
    }

    /// Forgets everything held, for when nobody is listening.
    pub fn reset(&mut self) {
        self.resampler = None;
        self.waiting.clear();
    }

    fn cut_frames(&mut self) -> Vec<EncodedAudioFrame> {
        let size = FRAME_SAMPLES * 2;
        let whole = self.waiting.len() / size;
        let mut frames = Vec::with_capacity(whole);
        for _ in 0..whole {
            let rest = self.waiting.split_off(size);
            let samples = std::mem::replace(&mut self.waiting, rest);
            frames.push(self.frame(&samples));
        }
        frames
    }

    fn frame(&mut self, samples: &[f32]) -> EncodedAudioFrame {
        let mut bytes = Vec::with_capacity(samples.len() * 4);
        for sample in samples {
            bytes.extend_from_slice(&clean(*sample).to_le_bytes());
        }
        let presentation_time = VideoTimestamp { value: self.emitted_samples, timescale: OUTPUT_RATE as i32 };
        self.emitted_samples += FRAME_SAMPLES as i64;
        EncodedAudioFrame { sample_count: FRAME_SAMPLES as u32, channel_count: OUTPUT_CHANNELS, presentation_time, samples: bytes }
    }
}

fn clean(sample: f32) -> f32 {
    if sample.is_finite() { sample.clamp(-SAMPLE_LIMIT, SAMPLE_LIMIT) } else { 0.0 }
}

/// Interleaved stereo from `channels` interleaved channels: a mono sound plays on both sides and anything wider is its
/// first two channels, the front pair, which is what the phones play of it.
pub fn to_stereo(samples: &[f32], channels: u32) -> Vec<f32> {
    let channels = channels as usize;
    match channels {
        0 => Vec::new(),
        1 => samples.iter().flat_map(|sample| [*sample, *sample]).collect(),
        2 => samples[..samples.len() / 2 * 2].to_vec(),
        _ => samples.chunks_exact(channels).flat_map(|frame| [frame[0], frame[1]]).collect(),
    }
}
