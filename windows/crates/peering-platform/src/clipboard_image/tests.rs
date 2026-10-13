use super::*;

fn info_header(width: i32, height: i32, bits: u16) -> Vec<u8> {
    let mut header = Vec::new();
    header.extend_from_slice(&40u32.to_le_bytes());
    header.extend_from_slice(&width.to_le_bytes());
    header.extend_from_slice(&height.to_le_bytes());
    header.extend_from_slice(&1u16.to_le_bytes());
    header.extend_from_slice(&bits.to_le_bytes());
    header.extend_from_slice(&[0; 24]);
    header
}

fn decode(png_bytes: &[u8]) -> (u32, u32, Vec<u8>) {
    let mut reader = png::Decoder::new(Cursor::new(png_bytes)).read_info().expect("a png");
    let mut buffer = vec![0; reader.output_buffer_size()];
    let frame = reader.next_frame(&mut buffer).expect("a frame");
    (frame.width, frame.height, buffer[..frame.buffer_size()].to_vec())
}

#[test]
fn a_bottom_up_24_bit_bitmap_becomes_a_top_down_png() {
    let mut dib = info_header(2, 2, 24);
    // Bottom row first, blue green red, each row padded to four bytes.
    dib.extend_from_slice(&[10, 20, 30, 40, 50, 60, 0, 0]);
    dib.extend_from_slice(&[1, 2, 3, 4, 5, 6, 0, 0]);
    let (width, height, rgba) = decode(&dib_to_png(&dib).expect("converts"));
    assert_eq!((width, height), (2, 2));
    assert_eq!(rgba, [3, 2, 1, 255, 6, 5, 4, 255, 30, 20, 10, 255, 60, 50, 40, 255]);
}

#[test]
fn a_top_down_bitmap_keeps_its_row_order() {
    let mut dib = info_header(1, -2, 32);
    dib.extend_from_slice(&[1, 2, 3, 0, 4, 5, 6, 0]);
    let (_, _, rgba) = decode(&dib_to_png(&dib).expect("converts"));
    assert_eq!(rgba, [3, 2, 1, 255, 6, 5, 4, 255]);
}

#[test]
fn a_32_bit_bitmap_that_stores_no_alpha_is_opaque() {
    let mut dib = info_header(1, 1, 32);
    dib.extend_from_slice(&[9, 8, 7, 0]);
    let (_, _, rgba) = decode(&dib_to_png(&dib).expect("converts"));
    assert_eq!(rgba, [7, 8, 9, 255]);
}

#[test]
fn a_palette_bitmap_is_not_converted() {
    let mut dib = info_header(1, 1, 8);
    dib.extend_from_slice(&[0; 8]);
    assert_eq!(dib_to_png(&dib), None);
}

#[test]
fn a_truncated_bitmap_is_not_converted() {
    let mut dib = info_header(4, 4, 32);
    dib.extend_from_slice(&[0; 16]);
    assert_eq!(dib_to_png(&dib), None);
    assert_eq!(dib_to_png(&[0; 10]), None);
}

#[test]
fn a_bitmap_claiming_a_huge_size_is_refused_before_anything_is_allocated() {
    let dib = info_header(i32::MAX, 2, 32);
    assert_eq!(dib_to_png(&dib), None);
}

#[test]
fn a_png_round_trips_through_the_bitmap_with_its_alpha() {
    let pixels = [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 255];
    let png_bytes = encode_png(2, 2, &pixels).expect("encodes");
    let dib = png_to_dib(&png_bytes).expect("converts to a bitmap");
    assert_eq!(dib.len(), V5_HEADER_BYTES + 16);
    assert_eq!(&dib[..4], &124u32.to_le_bytes());
    let (_, _, rgba) = decode(&dib_to_png(&dib).expect("converts back"));
    assert_eq!(rgba, pixels);
}

#[test]
fn something_that_is_not_a_png_is_not_converted() {
    assert_eq!(png_to_dib(b"not a png"), None);
}
