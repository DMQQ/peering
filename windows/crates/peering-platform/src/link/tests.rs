use super::*;

fn frame(sequence: u64) -> FrameHandoff<u64> {
    FrameHandoff { sequence, width: 1920, height: 1080, texture: sequence * 10 }
}

fn device(adapter: AdapterKey, name: &'static str) -> Option<BoundDevice<&'static str>> {
    Some(BoundDevice { adapter, device: name })
}

#[test]
fn packing_the_luid_keeps_both_halves() {
    assert_eq!(pack_luid(0, 1), 1);
    assert_eq!(pack_luid(1, 0), 1 << 32);
    assert_eq!(pack_luid(-1, u32::MAX), u64::MAX);
}

#[test]
fn a_frame_is_taken_once() {
    let mut link: FrameLink<&str, u64> = FrameLink::default();
    link.put_frame(frame(3));
    assert_eq!(link.take_frame().map(|taken| taken.sequence), Some(3));
    assert!(link.take_frame().is_none());
}

#[test]
fn a_newer_frame_replaces_one_not_yet_taken() {
    let mut link: FrameLink<&str, u64> = FrameLink::default();
    link.put_frame(frame(1));
    link.put_frame(frame(2));
    assert_eq!(link.take_frame().map(|taken| taken.sequence), Some(2));
}

#[test]
fn rebinding_the_same_adapter_keeps_the_frame() {
    let mut link = FrameLink::default();
    link.bind(device(7, "first"));
    link.put_frame(frame(4));
    link.bind(device(7, "first"));
    assert_eq!(link.take_frame().map(|taken| taken.sequence), Some(4));
}

#[test]
fn binding_another_adapter_drops_the_frame_it_came_from() {
    let mut link = FrameLink::default();
    link.bind(device(7, "first"));
    link.put_frame(frame(4));
    link.bind(device(9, "second"));
    assert!(link.take_frame().is_none());
    assert_eq!(link.device().map(|bound| bound.device), Some("second"));
}

#[test]
fn unbinding_the_capture_drops_its_frame() {
    let mut link = FrameLink::default();
    link.bind(device(7, "first"));
    link.put_frame(frame(4));
    link.bind(None);
    assert!(link.take_frame().is_none());
    assert!(link.device().is_none());
}

#[test]
fn the_encoder_reuses_its_session_on_the_same_adapter() {
    assert_eq!(binding_for(Some(7), 7), Binding::Reuse);
}

#[test]
fn the_encoder_rebinds_when_it_has_none_or_another_adapter() {
    assert_eq!(binding_for(None, 7), Binding::Rebind);
    assert_eq!(binding_for(Some(6), 7), Binding::Rebind);
}

#[test]
fn a_frame_at_the_configured_size_needs_no_resize() {
    assert_eq!(resize_for(Some((1920, 1080)), (1920, 1080)), None);
}

#[test]
fn a_changed_display_size_resizes_to_even_sides() {
    assert_eq!(resize_for(Some((1920, 1080)), (2560, 1441)), Some((2560, 1440)));
}

#[test]
fn a_capture_before_any_configure_always_sizes_the_encoder() {
    assert_eq!(resize_for(None, (1280, 720)), Some((1280, 720)));
}
