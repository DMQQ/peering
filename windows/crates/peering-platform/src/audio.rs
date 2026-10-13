//! The PC's sound through WASAPI loopback: whatever the default playback device plays. The decisions (how a mix format reads,
//! how much captured sound is kept, when a failed capture is tried again) are pure and tested on any OS; `audio/sys.rs`
//! calls the operating system.

mod queue;
#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::LoopbackAudio;

pub use queue::PacketQueue;

/// How the samples in a WASAPI buffer are laid out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SampleFormat {
    Float32,
    Pcm16,
    Pcm24,
    Pcm32,
}

const TAG_PCM: u32 = 1;
const TAG_IEEE_FLOAT: u32 = 3;
const TAG_EXTENSIBLE: u32 = 0xFFFE;

/// The layout a mix format describes. `extensible_tag` is the first four bytes of a `WAVE_FORMAT_EXTENSIBLE` sub format
/// (the format tag it stands for), read only when `tag` says the format is extensible.
pub fn sample_format(tag: u32, bits: u32, extensible_tag: Option<u32>) -> Option<SampleFormat> {
    let tag = if tag == TAG_EXTENSIBLE { extensible_tag? } else { tag };
    match (tag, bits) {
        (TAG_IEEE_FLOAT, 32) => Some(SampleFormat::Float32),
        (TAG_PCM, 16) => Some(SampleFormat::Pcm16),
        (TAG_PCM, 24) => Some(SampleFormat::Pcm24),
        (TAG_PCM, 32) => Some(SampleFormat::Pcm32),
        _ => None,
    }
}

impl SampleFormat {
    pub fn bytes_per_sample(self) -> usize {
        match self {
            Self::Float32 | Self::Pcm32 => 4,
            Self::Pcm24 => 3,
            Self::Pcm16 => 2,
        }
    }
}

/// The samples in `bytes` as Float32 in -1..1. A torn last sample is dropped.
pub fn decode_samples(bytes: &[u8], format: SampleFormat) -> Vec<f32> {
    let width = format.bytes_per_sample();
    bytes
        .chunks_exact(width)
        .map(|sample| match format {
            SampleFormat::Float32 => f32::from_le_bytes([sample[0], sample[1], sample[2], sample[3]]),
            SampleFormat::Pcm16 => f32::from(i16::from_le_bytes([sample[0], sample[1]])) / 32_768.0,
            SampleFormat::Pcm24 => (i32::from_le_bytes([0, sample[0], sample[1], sample[2]]) >> 8) as f32 / 8_388_608.0,
            SampleFormat::Pcm32 => i32::from_le_bytes([sample[0], sample[1], sample[2], sample[3]]) as f32 / 2_147_483_648.0,
        })
        .collect()
}

/// Seconds to wait before trying a capture again after `failures` failures in a row: 1 s doubling to 15 s.
pub fn retry_delay_seconds(failures: u32) -> f64 {
    let exponent = failures.saturating_sub(1).min(4);
    f64::from(1u32 << exponent).min(15.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_usual_mix_format_is_float32() {
        assert_eq!(sample_format(TAG_EXTENSIBLE, 32, Some(TAG_IEEE_FLOAT)), Some(SampleFormat::Float32));
        assert_eq!(sample_format(TAG_IEEE_FLOAT, 32, None), Some(SampleFormat::Float32));
    }

    #[test]
    fn integer_formats_are_recognised_by_width() {
        assert_eq!(sample_format(TAG_PCM, 16, None), Some(SampleFormat::Pcm16));
        assert_eq!(sample_format(TAG_EXTENSIBLE, 24, Some(TAG_PCM)), Some(SampleFormat::Pcm24));
        assert_eq!(sample_format(TAG_PCM, 32, None), Some(SampleFormat::Pcm32));
    }

    #[test]
    fn a_format_the_host_cannot_read_is_refused() {
        assert_eq!(sample_format(TAG_EXTENSIBLE, 32, None), None, "an extensible format needs its sub format");
        assert_eq!(sample_format(TAG_IEEE_FLOAT, 64, None), None);
        assert_eq!(sample_format(TAG_PCM, 8, None), None);
        assert_eq!(sample_format(0x0055, 16, None), None);
    }

    #[test]
    fn float_samples_are_read_little_endian() {
        let bytes = [0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0xBF];
        assert_eq!(decode_samples(&bytes, SampleFormat::Float32), vec![1.0, -0.5]);
    }

    #[test]
    fn sixteen_bit_samples_scale_to_one() {
        let bytes = [0x00, 0x80, 0xFF, 0x7F, 0x00, 0x40];
        let samples = decode_samples(&bytes, SampleFormat::Pcm16);
        assert_eq!(samples[0], -1.0);
        assert!((samples[1] - 0.999_97).abs() < 1e-4);
        assert_eq!(samples[2], 0.5);
    }

    #[test]
    fn twenty_four_bit_samples_keep_their_sign() {
        let bytes = [0x00, 0x00, 0x80, 0x00, 0x00, 0x40, 0xFF, 0xFF, 0x7F];
        let samples = decode_samples(&bytes, SampleFormat::Pcm24);
        assert_eq!(samples[0], -1.0);
        assert_eq!(samples[1], 0.5);
        assert!(samples[2] > 0.999);
    }

    #[test]
    fn thirty_two_bit_samples_scale_to_one() {
        let bytes = [0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x40];
        assert_eq!(decode_samples(&bytes, SampleFormat::Pcm32), vec![-1.0, 0.5]);
    }

    #[test]
    fn a_torn_last_sample_is_dropped() {
        assert_eq!(decode_samples(&[0x00, 0x00, 0x80], SampleFormat::Float32), Vec::<f32>::new());
    }

    #[test]
    fn a_failed_capture_is_retried_after_a_growing_wait() {
        let waits: Vec<f64> = (0..8).map(retry_delay_seconds).collect();
        assert_eq!(waits, vec![1.0, 1.0, 2.0, 4.0, 8.0, 15.0, 15.0, 15.0]);
    }
}
