//! Bounds on what a client may ask the encoder for. The numbers arrive off the wire, so the host clamps them rather than trusting the phone to stay sane.

pub const MAX_BITRATE_KBPS: u32 = 100_000;

const DEFAULT_MIN_BITRATE_BPS: f64 = 4_000_000.0;
const DEFAULT_MAX_BITRATE_BPS: f64 = 30_000_000.0;
const BITS_PER_PIXEL_PER_FRAME: f64 = 0.12;

/// `None` for a request that is not a bitrate at all (zero or negative).
pub fn clamped_bitrate_kbps(requested: i64) -> Option<u32> {
    if requested <= 0 {
        return None;
    }
    Some(requested.min(i64::from(MAX_BITRATE_KBPS)) as u32)
}

/// Scales with frame rate: a budget set too low arrives as a lower frame rate, since the encoder
/// drops frames rather than lowering quality.
pub fn default_bitrate_bps(width: u32, height: u32, fps: u32) -> u32 {
    let raw = f64::from(width) * f64::from(height) * BITS_PER_PIXEL_PER_FRAME * f64::from(fps);
    raw.clamp(DEFAULT_MIN_BITRATE_BPS, DEFAULT_MAX_BITRATE_BPS) as u32
}

/// 4:2:0 chroma subsampling cannot encode odd dimensions, so each side rounds down to even.
pub fn even_size(width: u32, height: u32) -> (u32, u32) {
    (width & !1, height & !1)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QualityTier {
    Low = 2_000,
    Medium = 8_000,
    High = 20_000,
}

impl QualityTier {
    /// The highest tier not above `kbps`, or `None` below the lowest tier.
    pub fn from_kbps(kbps: u32) -> Option<QualityTier> {
        [QualityTier::High, QualityTier::Medium, QualityTier::Low]
            .into_iter()
            .find(|tier| *tier as u32 <= kbps)
    }
}

/// A client's requested frame rate and bitrate. Zero means keep what the encoder already has.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamQualityRequest {
    pub fps: i64,
    pub bitrate_kbps: i64,
}

impl StreamQualityRequest {
    pub fn apply(&self, current_fps: u32, current_kbps: u32) -> (u32, u32) {
        let fps = if self.fps > 0 {
            self.fps.min(i64::from(u32::MAX)) as u32
        } else {
            current_fps
        };
        let kbps = clamped_bitrate_kbps(self.bitrate_kbps).unwrap_or(current_kbps);
        (fps, kbps)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bitrate_request_of_zero_or_less_is_not_a_bitrate() {
        assert_eq!(clamped_bitrate_kbps(0), None);
        assert_eq!(clamped_bitrate_kbps(-5), None);
    }

    #[test]
    fn a_bitrate_request_is_capped_at_the_maximum() {
        assert_eq!(clamped_bitrate_kbps(8_000), Some(8_000));
        assert_eq!(clamped_bitrate_kbps(100_000), Some(100_000));
        assert_eq!(clamped_bitrate_kbps(250_000), Some(MAX_BITRATE_KBPS));
        assert_eq!(clamped_bitrate_kbps(i64::MAX), Some(MAX_BITRATE_KBPS));
    }

    #[test]
    fn default_bitrate_follows_the_pixel_rate_formula() {
        assert_eq!(default_bitrate_bps(1920, 1080, 60), 14_929_920);
    }

    #[test]
    fn default_bitrate_is_raised_to_the_floor() {
        assert_eq!(default_bitrate_bps(640, 360, 30), 4_000_000);
    }

    #[test]
    fn default_bitrate_is_capped_at_the_ceiling() {
        assert_eq!(default_bitrate_bps(7680, 4320, 60), 30_000_000);
    }

    #[test]
    fn even_size_rounds_each_side_down_to_even() {
        assert_eq!(even_size(1921, 1081), (1920, 1080));
        assert_eq!(even_size(1920, 1080), (1920, 1080));
        assert_eq!(even_size(1, 0), (0, 0));
    }

    #[test]
    fn tier_lookup_picks_the_highest_tier_not_above_the_value() {
        assert_eq!(QualityTier::from_kbps(1_999), None);
        assert_eq!(QualityTier::from_kbps(2_000), Some(QualityTier::Low));
        assert_eq!(QualityTier::from_kbps(7_999), Some(QualityTier::Low));
        assert_eq!(QualityTier::from_kbps(8_000), Some(QualityTier::Medium));
        assert_eq!(QualityTier::from_kbps(19_999), Some(QualityTier::Medium));
        assert_eq!(QualityTier::from_kbps(100_000), Some(QualityTier::High));
    }

    #[test]
    fn zero_fps_and_bitrate_keep_the_current_values() {
        let request = StreamQualityRequest { fps: 0, bitrate_kbps: 0 };
        assert_eq!(request.apply(60, 12_000), (60, 12_000));
    }

    #[test]
    fn a_request_replaces_fps_and_clamps_the_bitrate() {
        let request = StreamQualityRequest { fps: 30, bitrate_kbps: 250_000 };
        assert_eq!(request.apply(60, 12_000), (30, MAX_BITRATE_KBPS));
    }

    #[test]
    fn a_negative_fps_keeps_the_current_frame_rate() {
        let request = StreamQualityRequest { fps: -1, bitrate_kbps: 5_000 };
        assert_eq!(request.apply(60, 12_000), (60, 5_000));
    }
}
