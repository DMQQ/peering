//! Converts between the device independent bitmap Windows keeps on the clipboard and the PNG the phones exchange. Pure, so it
//! tests on any OS; `clipboard/sys.rs` moves the bytes to and from the clipboard.

use std::io::Cursor;

use peering_wire::clipboard::MAX_IMAGE_BYTES;

const INFO_HEADER_BYTES: usize = 40;
const V5_HEADER_BYTES: usize = 124;
const BI_RGB: u32 = 0;
const BI_BITFIELDS: u32 = 3;
const SRGB_COLOUR_SPACE: u32 = 0x7352_4742;
const IMAGES_INTENT: u32 = 4;
const RED_MASK: u32 = 0x00FF_0000;
const GREEN_MASK: u32 = 0x0000_FF00;
const BLUE_MASK: u32 = 0x0000_00FF;
const ALPHA_MASK: u32 = 0xFF00_0000;
/// A picture of more pixels than this is refused before anything is allocated for it.
const MAX_PIXELS: usize = 64 * 1024 * 1024;

struct Header {
    header_bytes: usize,
    width: usize,
    height: usize,
    bottom_up: bool,
    bits_per_pixel: usize,
    masks: [u32; 4],
}

fn u32_at(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(bytes.get(offset..offset + 4)?.try_into().ok()?))
}

fn parse_header(dib: &[u8]) -> Option<Header> {
    let header_bytes = u32_at(dib, 0)? as usize;
    if header_bytes != INFO_HEADER_BYTES && header_bytes != V5_HEADER_BYTES {
        return None;
    }
    let width = i32::from_le_bytes(dib.get(4..8)?.try_into().ok()?);
    let height = i32::from_le_bytes(dib.get(8..12)?.try_into().ok()?);
    let bits_per_pixel = usize::from(u16::from_le_bytes(dib.get(14..16)?.try_into().ok()?));
    let compression = u32_at(dib, 16)?;
    if width <= 0 || height == 0 || !matches!(bits_per_pixel, 24 | 32) || !matches!(compression, BI_RGB | BI_BITFIELDS) {
        return None;
    }
    let masks = if header_bytes == V5_HEADER_BYTES && compression == BI_BITFIELDS {
        [u32_at(dib, 40)?, u32_at(dib, 44)?, u32_at(dib, 48)?, u32_at(dib, 52)?]
    } else if compression == BI_BITFIELDS {
        [u32_at(dib, 40)?, u32_at(dib, 44)?, u32_at(dib, 48)?, 0]
    } else {
        [RED_MASK, GREEN_MASK, BLUE_MASK, 0]
    };
    let mask_bytes = if header_bytes == INFO_HEADER_BYTES && compression == BI_BITFIELDS { 12 } else { 0 };
    let bottom_up = height > 0;
    let (width, height) = (width as usize, height.unsigned_abs() as usize);
    if width.checked_mul(height)? > MAX_PIXELS {
        return None;
    }
    Some(Header { header_bytes: header_bytes + mask_bytes, width, height, bottom_up, bits_per_pixel, masks })
}

/// Which byte of a little endian pixel holds the channel a mask names, when the mask is a whole byte.
fn byte_of(mask: u32) -> Option<usize> {
    match mask {
        0x0000_00FF => Some(0),
        0x0000_FF00 => Some(1),
        0x00FF_0000 => Some(2),
        0xFF00_0000 => Some(3),
        _ => None,
    }
}

/// A bitmap of 24 or 32 bits per pixel, as the PNG a phone can show. `None` for any other shape, which the caller treats as
/// "no picture on the clipboard".
pub fn dib_to_png(dib: &[u8]) -> Option<Vec<u8>> {
    let header = parse_header(dib)?;
    let pixel_bytes = header.bits_per_pixel / 8;
    let stride = (header.width * header.bits_per_pixel).div_ceil(32) * 4;
    let pixels = dib.get(header.header_bytes..)?;
    if pixels.len() < stride.checked_mul(header.height)? {
        return None;
    }
    let [red, green, blue, alpha] = [header.masks[0], header.masks[1], header.masks[2], header.masks[3]].map(byte_of);
    let (red, green, blue) = (red?, green?, blue?);
    let carries_alpha = header.bits_per_pixel == 32 && alpha.is_some();
    let mut rgba = Vec::with_capacity(header.width * header.height * 4);
    for row in 0..header.height {
        let source_row = if header.bottom_up { header.height - 1 - row } else { row };
        let line = &pixels[source_row * stride..source_row * stride + header.width * pixel_bytes];
        for pixel in line.chunks_exact(pixel_bytes) {
            let channel = if carries_alpha { alpha.map_or(255, |index| pixel[index]) } else { 255 };
            rgba.extend_from_slice(&[pixel[red], pixel[green], pixel[blue], channel]);
        }
    }
    if carries_alpha && rgba.chunks_exact(4).all(|pixel| pixel[3] == 0) {
        // A bitmap that stores no alpha at all reads as fully transparent otherwise.
        rgba.chunks_exact_mut(4).for_each(|pixel| pixel[3] = 255);
    }
    encode_png(header.width, header.height, &rgba)
}

fn encode_png(width: usize, height: usize, rgba: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, u32::try_from(width).ok()?, u32::try_from(height).ok()?);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    let mut writer = encoder.write_header().ok()?;
    writer.write_image_data(rgba).ok()?;
    writer.finish().ok()?;
    (out.len() <= MAX_IMAGE_BYTES).then_some(out)
}

/// A PNG as a `CF_DIBV5` block: 32 bits per pixel with alpha, stored bottom up.
pub fn png_to_dib(png_bytes: &[u8]) -> Option<Vec<u8>> {
    let mut decoder = png::Decoder::new(Cursor::new(png_bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().ok()?;
    let (width, height) = (reader.info().width as usize, reader.info().height as usize);
    if width == 0 || height == 0 || width.checked_mul(height)? > MAX_PIXELS {
        return None;
    }
    let mut buffer = vec![0u8; reader.output_buffer_size()];
    let frame = reader.next_frame(&mut buffer).ok()?;
    let channels = match frame.color_type {
        png::ColorType::Grayscale => 1,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Rgb => 3,
        png::ColorType::Rgba => 4,
        png::ColorType::Indexed => return None,
    };
    let line_bytes = width * channels;
    let mut dib = v5_header(width, height);
    dib.reserve(width * height * 4);
    for row in (0..height).rev() {
        let line = buffer.get(row * frame.line_size..row * frame.line_size + line_bytes)?;
        for pixel in line.chunks_exact(channels) {
            let (red, green, blue, alpha) = match channels {
                1 => (pixel[0], pixel[0], pixel[0], 255),
                2 => (pixel[0], pixel[0], pixel[0], pixel[1]),
                3 => (pixel[0], pixel[1], pixel[2], 255),
                _ => (pixel[0], pixel[1], pixel[2], pixel[3]),
            };
            dib.extend_from_slice(&[blue, green, red, alpha]);
        }
    }
    Some(dib)
}

fn v5_header(width: usize, height: usize) -> Vec<u8> {
    let image_bytes = (width * height * 4) as u32;
    let mut header = Vec::with_capacity(V5_HEADER_BYTES + image_bytes as usize);
    let mut put = |value: u32| header.extend_from_slice(&value.to_le_bytes());
    put(V5_HEADER_BYTES as u32);
    put(width as u32);
    put(height as u32);
    put(1 | (32 << 16));
    put(BI_BITFIELDS);
    put(image_bytes);
    put(0);
    put(0);
    put(0);
    put(0);
    put(RED_MASK);
    put(GREEN_MASK);
    put(BLUE_MASK);
    put(ALPHA_MASK);
    put(SRGB_COLOUR_SPACE);
    for _ in 0..9 {
        put(0);
    }
    for _ in 0..3 {
        put(0);
    }
    put(IMAGES_INTENT);
    put(0);
    put(0);
    put(0);
    header
}

#[cfg(test)]
mod tests;
