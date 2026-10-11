//! H.264 Annex-B (encoder output) to AVCC (length prefixed NAL units). See docs/protocol/video.md section 1.

use crate::framing::MAX_FRAME_LENGTH;
use thiserror::Error;

const START_CODE: [u8; 3] = [0, 0, 1];
const AVCC_START_CODE: [u8; 4] = [0, 0, 0, 1];
const LENGTH_PREFIX_SIZE: usize = 4;
const NAL_SLICE_IDR: u8 = 5;
const NAL_SPS: u8 = 7;
const NAL_PPS: u8 = 8;
const NAL_AUD: u8 = 9;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum AnnexBError {
    #[error("length prefix truncated: have {have} bytes, need 4")]
    TruncatedLength { have: usize },
    #[error("NAL unit declares {declared} bytes but only {available} remain")]
    LengthOverrun { declared: usize, available: usize },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConvertedFrame {
    pub avcc: Vec<u8>,
    pub is_keyframe: bool,
    pub sps: Option<Vec<u8>>,
    pub pps: Option<Vec<u8>>,
}

/// NAL payloads without their start codes. Trailing zero bytes are dropped: the leading zero of a
/// 4 byte start code lands at the end of the previous NAL, and it is not part of that NAL.
pub fn split_nals(annexb: &[u8]) -> Vec<&[u8]> {
    let mut nals = Vec::new();
    let mut payload_start = None;
    let mut index = 0;
    while index + START_CODE.len() <= annexb.len() {
        if annexb[index..index + START_CODE.len()] == START_CODE {
            if let Some(start) = payload_start {
                nals.push(trim_trailing_zeros(&annexb[start..index]));
            }
            index += START_CODE.len();
            payload_start = Some(index);
        } else {
            index += 1;
        }
    }
    if let Some(start) = payload_start {
        nals.push(trim_trailing_zeros(&annexb[start..]));
    }
    nals.retain(|nal| !nal.is_empty());
    nals
}

fn trim_trailing_zeros(nal: &[u8]) -> &[u8] {
    let end = nal.iter().rposition(|byte| *byte != 0).map_or(0, |last| last + 1);
    &nal[..end]
}

/// The H.264 `nal_unit_type`: the low five bits of the first byte.
pub fn h264_nal_type(nal: &[u8]) -> Option<u8> {
    nal.first().map(|header| header & 0x1F)
}

/// SPS, PPS and AUD are removed from `avcc`. SPS and PPS are returned for the config instead, because the
/// client builds its decoder from them and not from the frame.
pub fn annexb_to_avcc(annexb: &[u8]) -> ConvertedFrame {
    let mut frame = ConvertedFrame { avcc: Vec::with_capacity(annexb.len()), is_keyframe: false, sps: None, pps: None };
    for nal in split_nals(annexb) {
        match h264_nal_type(nal) {
            Some(NAL_SPS) => frame.sps = Some(nal.to_vec()),
            Some(NAL_PPS) => frame.pps = Some(nal.to_vec()),
            Some(NAL_AUD) | None => {}
            Some(kind) => {
                frame.is_keyframe |= kind == NAL_SLICE_IDR;
                push_length_prefixed(&mut frame.avcc, nal);
            }
        }
    }
    frame
}

fn push_length_prefixed(out: &mut Vec<u8>, nal: &[u8]) {
    debug_assert!(nal.len() <= MAX_FRAME_LENGTH as usize, "a NAL unit larger than a frame cannot be sent");
    out.extend_from_slice(&(nal.len() as u32).to_be_bytes());
    out.extend_from_slice(nal);
}

pub fn avcc_to_annexb(avcc: &[u8]) -> Result<Vec<u8>, AnnexBError> {
    let mut out = Vec::with_capacity(avcc.len());
    let mut rest = avcc;
    while !rest.is_empty() {
        let Some((prefix, body)) = rest.split_first_chunk::<LENGTH_PREFIX_SIZE>() else {
            return Err(AnnexBError::TruncatedLength { have: rest.len() });
        };
        let declared = u32::from_be_bytes(*prefix) as usize;
        let Some((nal, after)) = body.split_at_checked(declared) else {
            return Err(AnnexBError::LengthOverrun { declared, available: body.len() });
        };
        out.extend_from_slice(&AVCC_START_CODE);
        out.extend_from_slice(nal);
        rest = after;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SPS: [u8; 4] = [0x67, 0x64, 0x00, 0x1f];
    const PPS: [u8; 3] = [0x68, 0xee, 0x3c];
    const AUD: [u8; 2] = [0x09, 0xf0];
    const IDR: [u8; 4] = [0x65, 0x88, 0x84, 0x21];
    const DELTA: [u8; 3] = [0x41, 0x9a, 0x24];

    fn with_start_codes(parts: &[(&[u8], bool)]) -> Vec<u8> {
        let mut out = Vec::new();
        for (nal, four_byte) in parts {
            if *four_byte {
                out.push(0);
            }
            out.extend_from_slice(&START_CODE);
            out.extend_from_slice(nal);
        }
        out
    }

    fn length_prefixed(nals: &[&[u8]]) -> Vec<u8> {
        let mut out = Vec::new();
        for nal in nals {
            push_length_prefixed(&mut out, nal);
        }
        out
    }

    #[test]
    fn three_and_four_byte_start_codes_split_the_same_way() {
        let annexb = with_start_codes(&[(&SPS, true), (&PPS, false), (&IDR, true), (&DELTA, false)]);
        assert_eq!(split_nals(&annexb), vec![&SPS[..], &PPS[..], &IDR[..], &DELTA[..]]);
    }

    #[test]
    fn trailing_zero_bytes_are_not_part_of_a_nal() {
        let annexb = [&START_CODE[..], &DELTA[..], &[0, 0, 0][..]].concat();
        assert_eq!(split_nals(&annexb), vec![&DELTA[..]]);
    }

    #[test]
    fn empty_input_and_input_without_a_start_code_have_no_nals() {
        assert!(split_nals(&[]).is_empty());
        assert!(split_nals(&[0x65, 0x88, 0x84]).is_empty());
        assert_eq!(annexb_to_avcc(&[]), ConvertedFrame { avcc: Vec::new(), is_keyframe: false, sps: None, pps: None });
    }

    #[test]
    fn a_keyframe_lifts_sps_and_pps_and_drops_the_aud() {
        let annexb = with_start_codes(&[(&AUD, true), (&SPS, false), (&PPS, false), (&IDR, false)]);
        let frame = annexb_to_avcc(&annexb);
        assert!(frame.is_keyframe);
        assert_eq!(frame.sps.as_deref(), Some(&SPS[..]));
        assert_eq!(frame.pps.as_deref(), Some(&PPS[..]));
        assert_eq!(frame.avcc, length_prefixed(&[&IDR]));
    }

    #[test]
    fn a_delta_frame_has_no_parameter_sets_and_is_not_a_keyframe() {
        let annexb = with_start_codes(&[(&AUD, true), (&DELTA, false)]);
        let frame = annexb_to_avcc(&annexb);
        assert!(!frame.is_keyframe);
        assert_eq!(frame.sps, None);
        assert_eq!(frame.pps, None);
        assert_eq!(frame.avcc, length_prefixed(&[&DELTA]));
    }

    #[test]
    fn avcc_survives_a_trip_through_annexb_and_back() {
        let avcc = length_prefixed(&[&IDR, &DELTA]);
        let annexb = avcc_to_annexb(&avcc).unwrap();
        assert_eq!(annexb, with_start_codes(&[(&IDR, true), (&DELTA, true)]));
        assert_eq!(annexb_to_avcc(&annexb).avcc, avcc);
    }

    #[test]
    fn a_length_past_the_end_is_rejected() {
        let avcc = [0, 0, 0, 9, 1, 2];
        assert_eq!(avcc_to_annexb(&avcc), Err(AnnexBError::LengthOverrun { declared: 9, available: 2 }));
    }

    #[test]
    fn a_length_prefix_cut_short_is_rejected() {
        assert_eq!(avcc_to_annexb(&[0, 0]), Err(AnnexBError::TruncatedLength { have: 2 }));
    }

    #[test]
    fn empty_avcc_converts_to_empty_annexb() {
        assert_eq!(avcc_to_annexb(&[]), Ok(Vec::new()));
    }
}
