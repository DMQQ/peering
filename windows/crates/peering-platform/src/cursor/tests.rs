use super::*;

fn color_shape(width: u32, height: u32, pixel: [u8; 4]) -> CursorShape {
    let data = pixel.repeat((width * height) as usize);
    CursorShape::new(ShapeKind::Color, width, height, width * 4, data).expect("a valid shape")
}

fn patch(width: u32, height: u32, pixel: [u8; 4]) -> Vec<u8> {
    pixel.repeat((width * height) as usize)
}

fn everywhere(width: u32, height: u32) -> Placement {
    Placement { x: 0, y: 0, width, height, shape_x: 0, shape_y: 0 }
}

#[test]
fn the_dxgi_shape_types_map_to_kinds() {
    assert_eq!(ShapeKind::from_dxgi(1), Some(ShapeKind::Monochrome));
    assert_eq!(ShapeKind::from_dxgi(2), Some(ShapeKind::Color));
    assert_eq!(ShapeKind::from_dxgi(4), Some(ShapeKind::MaskedColor));
    assert_eq!(ShapeKind::from_dxgi(3), None);
}

#[test]
fn a_shape_with_a_short_buffer_or_no_size_is_refused() {
    assert!(CursorShape::new(ShapeKind::Color, 2, 2, 8, vec![0; 15]).is_none());
    assert!(CursorShape::new(ShapeKind::Color, 0, 2, 0, vec![]).is_none());
    assert!(CursorShape::new(ShapeKind::Color, 2, 2, 4, vec![0; 16]).is_none(), "a pitch narrower than a row");
    assert!(CursorShape::new(ShapeKind::Color, MAX_SIDE + 1, 1, (MAX_SIDE + 1) * 4, vec![0; 4 * (MAX_SIDE as usize + 1)]).is_none());
}

#[test]
fn a_monochrome_buffer_counts_both_masks_in_its_height() {
    let shape = CursorShape::new(ShapeKind::Monochrome, 8, 4, 1, vec![0; 4]).expect("two rows of mask pairs");
    assert_eq!((shape.width(), shape.height()), (8, 2));
    assert!(CursorShape::new(ShapeKind::Monochrome, 8, 4, 1, vec![0; 3]).is_none());
}

#[test]
fn an_opaque_colour_pixel_replaces_the_screen() {
    let shape = color_shape(1, 1, [10, 20, 30, 255]);
    let mut pixels = patch(1, 1, [200, 200, 200, 255]);
    shape.draw(&mut pixels, 4, &everywhere(1, 1));
    assert_eq!(pixels, vec![10, 20, 30, 255]);
}

#[test]
fn a_clear_colour_pixel_leaves_the_screen_alone() {
    let shape = color_shape(1, 1, [10, 20, 30, 0]);
    let mut pixels = patch(1, 1, [200, 100, 50, 255]);
    shape.draw(&mut pixels, 4, &everywhere(1, 1));
    assert_eq!(pixels, vec![200, 100, 50, 255]);
}

#[test]
fn a_half_clear_colour_pixel_mixes() {
    let shape = color_shape(1, 1, [0, 0, 0, 128]);
    let mut pixels = patch(1, 1, [200, 200, 200, 255]);
    shape.draw(&mut pixels, 4, &everywhere(1, 1));
    assert_eq!(pixels, vec![100, 100, 100, 255]);
}

#[test]
fn a_masked_pixel_with_a_zero_mask_replaces_and_otherwise_inverts_by_xor() {
    let replace = CursorShape::new(ShapeKind::MaskedColor, 1, 1, 4, vec![1, 2, 3, 0]).expect("valid");
    let xor = CursorShape::new(ShapeKind::MaskedColor, 1, 1, 4, vec![0xFF, 0x0F, 0x00, 0xFF]).expect("valid");
    let mut pixels = patch(1, 1, [0xF0, 0xF0, 0xF0, 255]);
    xor.draw(&mut pixels, 4, &everywhere(1, 1));
    assert_eq!(pixels, vec![0x0F, 0xFF, 0xF0, 255]);
    replace.draw(&mut pixels, 4, &everywhere(1, 1));
    assert_eq!(pixels, vec![1, 2, 3, 255]);
}

#[test]
fn a_monochrome_pointer_applies_and_then_xor_masks() {
    // Four pixels from the top bit down. AND: 1 0 1 0 (keep, black, keep, black). XOR: 0 0 1 1.
    let shape = CursorShape::new(ShapeKind::Monochrome, 4, 2, 1, vec![0b1010_0000, 0b0011_0000]).expect("valid");
    let mut pixels = patch(4, 1, [100, 100, 100, 255]);
    shape.draw(&mut pixels, 16, &everywhere(4, 1));
    assert_eq!(&pixels[0..4], &[100, 100, 100, 255], "kept");
    assert_eq!(&pixels[4..8], &[0, 0, 0, 255], "black");
    assert_eq!(&pixels[8..12], &[155, 155, 155, 255], "kept and inverted");
    assert_eq!(&pixels[12..16], &[255, 255, 255, 255], "black and inverted is white");
}

#[test]
fn a_pointer_inside_the_frame_is_placed_whole() {
    assert_eq!(place((100, 100), (10, 20), 5, 6), Some(Placement { x: 5, y: 6, width: 10, height: 20, shape_x: 0, shape_y: 0 }));
}

#[test]
fn a_pointer_over_the_top_left_edge_loses_the_part_off_screen() {
    assert_eq!(place((100, 100), (10, 20), -4, -5), Some(Placement { x: 0, y: 0, width: 6, height: 15, shape_x: 4, shape_y: 5 }));
}

#[test]
fn a_pointer_over_the_bottom_right_edge_loses_the_part_off_screen() {
    assert_eq!(place((100, 100), (10, 20), 95, 90), Some(Placement { x: 95, y: 90, width: 5, height: 10, shape_x: 0, shape_y: 0 }));
}

#[test]
fn a_pointer_wholly_off_screen_is_not_placed() {
    assert_eq!(place((100, 100), (10, 10), 100, 0), None);
    assert_eq!(place((100, 100), (10, 10), -10, 0), None);
    assert_eq!(place((100, 100), (10, 10), 0, 150), None);
}

#[test]
fn drawing_a_clipped_pointer_uses_the_right_part_of_it() {
    // Two columns: red then blue. Clipped so only the blue column shows at x = 0.
    let shape = CursorShape::new(ShapeKind::Color, 2, 1, 8, vec![0, 0, 255, 255, 255, 0, 0, 255]).expect("valid");
    let placement = place((4, 1), (2, 1), -1, 0).expect("half is on screen");
    let mut pixels = patch(1, 1, [9, 9, 9, 255]);
    shape.draw(&mut pixels, 4, &placement);
    assert_eq!(pixels, vec![255, 0, 0, 255]);
}

#[test]
fn a_patch_row_pitch_wider_than_the_row_is_respected() {
    let shape = color_shape(1, 2, [1, 1, 1, 255]);
    let mut pixels = vec![9u8; 16];
    shape.draw(&mut pixels, 8, &everywhere(1, 2));
    assert_eq!(&pixels[0..3], &[1, 1, 1]);
    assert_eq!(&pixels[4..8], &[9, 9, 9, 9], "the padding is untouched");
    assert_eq!(&pixels[8..11], &[1, 1, 1]);
}

#[test]
fn only_a_move_a_show_or_a_new_shape_asks_for_a_new_frame() {
    let mut state = PointerState::default();
    let shape = color_shape(2, 2, [0, 0, 0, 255]);
    assert!(state.update(Some(((5, 5), true)), Some(shape.clone())));
    assert!(!state.update(Some(((5, 5), true)), None), "nothing changed");
    assert!(!state.update(None, None), "a frame with no pointer report");
    assert!(state.update(Some(((6, 5), true)), None), "moved");
    assert!(state.update(Some(((6, 5), false)), None), "hidden");
    assert!(!state.update(None, Some(shape)), "the same shape again");
    assert!(state.update(None, Some(color_shape(3, 3, [0, 0, 0, 255]))), "another shape");
}

#[test]
fn a_hidden_pointer_or_one_without_a_shape_is_not_drawn() {
    let mut state = PointerState::default();
    assert!(state.visible().is_none());
    state.update(Some(((1, 2), true)), None);
    assert!(state.visible().is_none(), "no shape yet");
    state.update(None, Some(color_shape(1, 1, [0, 0, 0, 255])));
    assert_eq!(state.visible().map(|(_, at)| at), Some((1, 2)));
    state.update(Some(((1, 2), false)), None);
    assert!(state.visible().is_none());
    state.reset();
    assert!(state.visible().is_none());
}
