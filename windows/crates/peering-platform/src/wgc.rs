//! Window capture through Windows.Graphics.Capture. The rule for when the frame pool must change size is pure and tested on any
//! OS; `wgc/sys.rs` makes the calls.

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::WindowCapture;

/// Whether the pool must be made again for a frame whose content is `content` pixels while the pool holds `pool`. A window the
/// person resizes delivers frames of the new size; they are read at once and the pool follows.
pub fn pool_needs_recreating(pool: (u32, u32), content: (u32, u32)) -> bool {
    content.0 > 0 && content.1 > 0 && pool != content
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_frame_of_another_size_asks_for_a_new_pool() {
        assert!(pool_needs_recreating((800, 600), (1024, 600)));
        assert!(!pool_needs_recreating((800, 600), (800, 600)));
    }

    #[test]
    fn an_empty_content_size_never_does() {
        assert!(!pool_needs_recreating((800, 600), (0, 0)));
        assert!(!pool_needs_recreating((800, 600), (800, 0)));
    }
}
