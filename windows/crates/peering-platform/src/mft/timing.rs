//! Media Foundation times are in 100 ns units. The wire timestamp keeps that scale, so no rounding is lost.

use peering_wire::video::VideoTimestamp;

pub const HUNDRED_NANOSECONDS_PER_SECOND: i64 = 10_000_000;

/// Presentation time of the frame with this capture sequence. Dropped captures leave gaps; the client only orders by it.
pub fn frame_time(sequence: u64, fps: u32) -> i64 {
    let scale = u128::from(HUNDRED_NANOSECONDS_PER_SECOND.unsigned_abs());
    let hundred_nanoseconds = u128::from(sequence) * scale / u128::from(fps.max(1));
    i64::try_from(hundred_nanoseconds).unwrap_or(i64::MAX)
}

pub fn frame_duration(fps: u32) -> i64 {
    HUNDRED_NANOSECONDS_PER_SECOND / i64::from(fps.max(1))
}

pub fn video_timestamp(hundred_nanoseconds: i64) -> VideoTimestamp {
    VideoTimestamp { value: hundred_nanoseconds, timescale: HUNDRED_NANOSECONDS_PER_SECOND as i32 }
}
