//! Maps a normalised 0..1 point from the phone onto desktop coordinates. Not aspect-corrected: (0,0) is the top-left of the captured content and (1,1) its bottom-right whatever the aspect ratio.

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InputTransform {
    pub origin_x: f64,
    pub origin_y: f64,
    pub pixel_width: f64,
    pub pixel_height: f64,
    pub scale: f64,
}

impl InputTransform {
    pub fn global_point(&self, x: f64, y: f64) -> (f64, f64) {
        let scale = self.effective_scale();
        let x = x.clamp(0.0, 1.0);
        let y = y.clamp(0.0, 1.0);
        (
            self.origin_x + x * self.pixel_width / scale,
            self.origin_y + y * self.pixel_height / scale,
        )
    }

    pub fn normalized_point(&self, global_x: f64, global_y: f64) -> (f64, f64) {
        if self.pixel_width <= 0.0 || self.pixel_height <= 0.0 {
            return (0.0, 0.0);
        }
        let scale = self.effective_scale();
        (
            (global_x - self.origin_x) * scale / self.pixel_width,
            (global_y - self.origin_y) * scale / self.pixel_height,
        )
    }

    fn effective_scale(&self) -> f64 {
        if self.scale > 0.0 { self.scale } else { 1.0 }
    }
}

/// Coordinates for `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`, which span the whole virtual screen
/// with 0 at its left edge and 65535 at its right edge, so the last pixel is `width - 1`.
pub fn to_absolute_mouse(
    desktop_x: f64,
    desktop_y: f64,
    virtual_left: i32,
    virtual_top: i32,
    virtual_width: i32,
    virtual_height: i32,
) -> (i32, i32) {
    (
        absolute_axis(desktop_x, virtual_left, virtual_width),
        absolute_axis(desktop_y, virtual_top, virtual_height),
    )
}

fn absolute_axis(desktop: f64, virtual_start: i32, virtual_span: i32) -> i32 {
    if virtual_span <= 1 {
        return 0;
    }
    let span = f64::from(virtual_span - 1);
    let scaled = (desktop - f64::from(virtual_start)) * 65535.0 / span;
    scaled.round().clamp(0.0, 65535.0) as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    fn display(origin_x: f64, origin_y: f64, pixel_width: f64, pixel_height: f64, scale: f64) -> InputTransform {
        InputTransform { origin_x, origin_y, pixel_width, pixel_height, scale }
    }

    #[test]
    fn negative_origin_maps_a_monitor_left_of_the_primary() {
        let t = display(-1920.0, 0.0, 1920.0, 1080.0, 1.0);
        let (x, y) = t.global_point(0.0, 0.0);
        assert!(close(x, -1920.0) && close(y, 0.0));
        let (x, y) = t.global_point(1.0, 1.0);
        assert!(close(x, 0.0) && close(y, 1080.0));
    }

    #[test]
    fn scale_two_halves_the_desktop_distance() {
        let t = display(0.0, 0.0, 3840.0, 2160.0, 2.0);
        let (x, y) = t.global_point(1.0, 1.0);
        assert!(close(x, 1920.0) && close(y, 1080.0));
    }

    #[test]
    fn a_non_positive_scale_is_treated_as_one() {
        let t = display(0.0, 0.0, 1920.0, 1080.0, 0.0);
        assert_eq!(t.global_point(1.0, 1.0), (1920.0, 1080.0));
        assert_eq!(t.normalized_point(960.0, 540.0), (0.5, 0.5));
    }

    #[test]
    fn points_outside_the_unit_square_are_clamped() {
        let t = display(100.0, 50.0, 800.0, 600.0, 1.0);
        assert_eq!(t.global_point(-1.0, 2.0), t.global_point(0.0, 1.0));
        assert_eq!(t.global_point(3.0, -0.5), t.global_point(1.0, 0.0));
    }

    #[test]
    fn normalised_points_round_trip_through_the_desktop() {
        let t = display(-1280.0, 200.0, 2560.0, 1440.0, 2.0);
        let (gx, gy) = t.global_point(0.25, 0.75);
        let (nx, ny) = t.normalized_point(gx, gy);
        assert!(close(nx, 0.25) && close(ny, 0.75));
    }

    #[test]
    fn zero_pixel_size_normalises_to_the_origin() {
        let t = display(10.0, 10.0, 0.0, 0.0, 1.0);
        assert_eq!(t.normalized_point(500.0, 500.0), (0.0, 0.0));
    }

    #[test]
    fn absolute_mouse_corners_map_to_zero_and_full_range() {
        assert_eq!(to_absolute_mouse(0.0, 0.0, 0, 0, 1920, 1080), (0, 0));
        assert_eq!(to_absolute_mouse(1919.0, 1079.0, 0, 0, 1920, 1080), (65535, 65535));
    }

    #[test]
    fn absolute_mouse_handles_a_virtual_screen_with_negative_left() {
        assert_eq!(to_absolute_mouse(-1920.0, 0.0, -1920, 0, 3840, 1080), (0, 0));
        assert_eq!(to_absolute_mouse(1919.0, 1079.0, -1920, 0, 3840, 1080), (65535, 65535));
        assert_eq!(to_absolute_mouse(-960.0, 540.0, -1920, 0, 3840, 1080), (16388, 32798));
    }

    #[test]
    fn absolute_mouse_clamps_outside_the_virtual_screen() {
        assert_eq!(to_absolute_mouse(-50.0, 5000.0, 0, 0, 1920, 1080), (0, 65535));
    }

    #[test]
    fn absolute_mouse_guards_a_span_of_one_or_less() {
        assert_eq!(to_absolute_mouse(5.0, 5.0, 5, 5, 1, 0), (0, 0));
    }
}
