//! BGRA to NV12. The GPU path lives in `convert/sys.rs`; this file holds the layout arithmetic and a CPU reference
//! of the same BT.709 limited-range maths that the GPU video processor is configured for.

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::Nv12Converter;

const BYTES_PER_BGRA_PIXEL: usize = 4;

/// Bytes in an NV12 frame: a full luma plane, then interleaved 2x2-subsampled chroma. Odd sizes round the chroma up.
pub fn nv12_size(width: u32, height: u32) -> usize {
    let luma = width as usize * height as usize;
    let chroma_samples = width.div_ceil(2) as usize * height.div_ceil(2) as usize;
    luma + chroma_samples * 2
}

/// `row_bytes` rounded up to a multiple of `alignment`. An alignment of 0 or 1 returns `row_bytes` unchanged.
pub fn aligned_pitch(row_bytes: u32, alignment: u32) -> u32 {
    if alignment <= 1 {
        return row_bytes;
    }
    let aligned = u64::from(row_bytes).div_ceil(u64::from(alignment)) * u64::from(alignment);
    u32::try_from(aligned).unwrap_or(u32::MAX)
}

/// Tightly packed NV12 (pitch equals width) from tightly packed BGRA. Returns an empty vector for odd or zero
/// dimensions and for a buffer shorter than `width * height * 4`.
pub fn bgra_to_nv12_cpu(width: u32, height: u32, bgra: &[u8]) -> Vec<u8> {
    let (w, h) = (width as usize, height as usize);
    let even = w > 0 && h > 0 && w % 2 == 0 && h % 2 == 0;
    if !even || bgra.len() < w * h * BYTES_PER_BGRA_PIXEL {
        return Vec::new();
    }
    let mut out = vec![0u8; nv12_size(width, height)];
    let (luma, chroma) = out.split_at_mut(w * h);
    for (index, pixel) in bgra.chunks_exact(BYTES_PER_BGRA_PIXEL).take(w * h).enumerate() {
        luma[index] = to_byte(bt709_limited(pixel).0);
    }
    for block_row in 0..h / 2 {
        for block_column in 0..w / 2 {
            let (cb, cr) = block_chroma(bgra, w, block_column * 2, block_row * 2);
            let offset = block_row * w + block_column * 2;
            chroma[offset] = to_byte(cb);
            chroma[offset + 1] = to_byte(cr);
        }
    }
    out
}

/// Chroma averaged over the 2x2 block whose top-left pixel is (x, y).
fn block_chroma(bgra: &[u8], width: usize, x: usize, y: usize) -> (f64, f64) {
    let mut cb_sum = 0.0;
    let mut cr_sum = 0.0;
    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        let start = ((y + dy) * width + (x + dx)) * BYTES_PER_BGRA_PIXEL;
        let (_, cb, cr) = bt709_limited(&bgra[start..start + BYTES_PER_BGRA_PIXEL]);
        cb_sum += cb;
        cr_sum += cr;
    }
    (cb_sum / 4.0, cr_sum / 4.0)
}

/// (Y, Cb, Cr) as floats in 8-bit limited-range code values before rounding.
fn bt709_limited(pixel: &[u8]) -> (f64, f64, f64) {
    let (blue, green, red) = (f64::from(pixel[0]), f64::from(pixel[1]), f64::from(pixel[2]));
    let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
    let cb = -0.1146 * red - 0.3854 * green + 0.5 * blue;
    let cr = 0.5 * red - 0.4542 * green - 0.0458 * blue;
    (16.0 + 219.0 * luma / 255.0, 128.0 + 224.0 * cb / 255.0, 128.0 + 224.0 * cr / 255.0)
}

fn to_byte(value: f64) -> u8 {
    value.round().clamp(0.0, 255.0) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(width: u32, height: u32, bgra: [u8; 4]) -> Vec<u8> {
        bgra.iter().copied().cycle().take((width * height) as usize * 4).collect()
    }

    #[test]
    fn nv12_size_of_1080p_is_one_and_a_half_bytes_per_pixel() {
        assert_eq!(nv12_size(1920, 1080), 3_110_400);
    }

    #[test]
    fn nv12_size_rounds_odd_chroma_up() {
        assert_eq!(nv12_size(3, 3), 9 + 2 * 2 * 2);
    }

    #[test]
    fn aligned_pitch_rounds_up_to_the_alignment() {
        assert_eq!(aligned_pitch(1920 * 4, 256), 7680);
        assert_eq!(aligned_pitch(1921, 16), 1936);
        assert_eq!(aligned_pitch(1936, 16), 1936);
    }

    #[test]
    fn aligned_pitch_with_no_alignment_is_unchanged() {
        assert_eq!(aligned_pitch(1001, 0), 1001);
        assert_eq!(aligned_pitch(1001, 1), 1001);
    }

    #[test]
    fn white_becomes_luma_235_and_neutral_chroma() {
        let out = bgra_to_nv12_cpu(2, 2, &solid(2, 2, [255, 255, 255, 255]));
        assert_eq!(out, vec![235, 235, 235, 235, 128, 128]);
    }

    #[test]
    fn black_becomes_luma_16_and_neutral_chroma() {
        let out = bgra_to_nv12_cpu(2, 2, &solid(2, 2, [0, 0, 0, 255]));
        assert_eq!(out, vec![16, 16, 16, 16, 128, 128]);
    }

    #[test]
    fn pure_red_becomes_bt709_limited_63_102_240() {
        let red_bgra = [0, 0, 255, 255];
        let out = bgra_to_nv12_cpu(2, 2, &solid(2, 2, red_bgra));
        assert_eq!(out, vec![63, 63, 63, 63, 102, 240]);
    }

    #[test]
    fn chroma_is_the_average_of_each_two_by_two_block() {
        let mut bgra = solid(2, 2, [0, 0, 0, 255]);
        bgra[0..4].copy_from_slice(&[0, 0, 255, 255]);
        let out = bgra_to_nv12_cpu(2, 2, &bgra);
        assert_eq!(&out[4..6], &[122, 156]);
    }

    #[test]
    fn output_length_matches_nv12_size() {
        let out = bgra_to_nv12_cpu(4, 2, &solid(4, 2, [10, 20, 30, 255]));
        assert_eq!(out.len(), nv12_size(4, 2));
    }

    #[test]
    fn odd_or_empty_or_short_input_gives_nothing() {
        assert!(bgra_to_nv12_cpu(3, 2, &solid(3, 2, [0, 0, 0, 0])).is_empty());
        assert!(bgra_to_nv12_cpu(0, 0, &[]).is_empty());
        assert!(bgra_to_nv12_cpu(2, 2, &[0; 15]).is_empty());
    }
}
