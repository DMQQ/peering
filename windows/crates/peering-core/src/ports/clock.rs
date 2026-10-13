/// Time source. `now_seconds` is monotonic and only meaningful as a difference; `unix_seconds` is wall time.
pub trait Clock {
    fn now_seconds(&self) -> f64;
    fn unix_seconds(&self) -> u64;
}
