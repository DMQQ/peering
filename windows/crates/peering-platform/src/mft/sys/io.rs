//! Sample handling for the encoder: wrapping a capture texture, timing it, feeding `ProcessInput` and draining
//! `ProcessOutput` into Annex-B bytes.

use super::Session;
use std::mem::ManuallyDrop;
use std::ptr::null_mut;
use windows::core::{Interface, Result as WinResult};
use windows::Win32::Foundation::BOOL;
use windows::Win32::Graphics::Direct3D11::ID3D11Texture2D;
use windows::Win32::Media::MediaFoundation::{
    MFCreateDXGISurfaceBuffer, MFCreateMemoryBuffer, MFCreateSample, IMFSample, MFT_OUTPUT_DATA_BUFFER,
    MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES, MFT_OUTPUT_STREAM_PROVIDES_SAMPLES, MF_E_NOTACCEPTING,
    MF_E_TRANSFORM_NEED_MORE_INPUT, MF_E_TRANSFORM_STREAM_CHANGE,
};

/// One encoder output sample: Annex-B bytes and the presentation time in 100 ns units.
pub(in crate::mft) struct EncodedBytes {
    pub(in crate::mft) annexb: Vec<u8>,
    pub(in crate::mft) hundred_nanoseconds: i64,
}

pub(in crate::mft) fn wrap_texture(texture: &ID3D11Texture2D) -> WinResult<IMFSample> {
    // SAFETY: the texture is a live D3D11 resource; the buffer and sample each take their own reference to it.
    unsafe {
        let buffer = MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, texture, 0, BOOL(0))?;
        let sample = MFCreateSample()?;
        sample.AddBuffer(&buffer)?;
        Ok(sample)
    }
}

pub(in crate::mft) fn set_timing(sample: &IMFSample, hundred_nanoseconds: i64, duration: i64) -> WinResult<()> {
    // SAFETY: the sample is live; both values are plain 64-bit times.
    unsafe {
        sample.SetSampleTime(hundred_nanoseconds)?;
        sample.SetSampleDuration(duration)
    }
}

/// Feeds one sample and returns every output the encoder has ready. A full input queue is drained and retried once.
pub(in crate::mft) fn submit_and_drain(session: &Session, sample: &IMFSample) -> WinResult<Vec<EncodedBytes>> {
    if let Some(events) = &session.events {
        return super::events::submit_and_collect(session, events, sample);
    }
    let mut outputs = Vec::new();
    // SAFETY: the sample is live; ProcessInput takes its own reference to it.
    match unsafe { session.transform.ProcessInput(0, sample, 0) } {
        Ok(()) => {}
        Err(error) if error.code() == MF_E_NOTACCEPTING => {
            drain(session, &mut outputs)?;
            // SAFETY: as above; the queue was emptied by the drain.
            unsafe { session.transform.ProcessInput(0, sample, 0)? };
        }
        Err(error) => return Err(error),
    }
    drain(session, &mut outputs)?;
    Ok(outputs)
}

pub(super) fn drain(session: &Session, outputs: &mut Vec<EncodedBytes>) -> WinResult<()> {
    loop {
        let mut buffers = [output_buffer(session)?];
        let mut status = 0u32;
        // SAFETY: one initialised output buffer is passed; on return the MFT has filled or left its sample.
        let result = unsafe { session.transform.ProcessOutput(0, &mut buffers, &mut status) };
        let [buffer] = buffers;
        let sample = take_sample(buffer);
        match result {
            Ok(()) => {
                if let Some(sample) = sample {
                    outputs.push(read_sample(&sample)?);
                }
            }
            Err(error) if error.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(()),
            Err(error) if error.code() == MF_E_TRANSFORM_STREAM_CHANGE => renegotiate_output(session)?,
            Err(error) => return Err(error),
        }
    }
}

pub(super) fn output_buffer(session: &Session) -> WinResult<MFT_OUTPUT_DATA_BUFFER> {
    let sample = if provides_samples(session) { None } else { Some(allocate_output_sample(session.output_info.cbSize)?) };
    Ok(MFT_OUTPUT_DATA_BUFFER {
        dwStreamID: 0,
        pSample: ManuallyDrop::new(sample),
        dwStatus: 0,
        pEvents: ManuallyDrop::new(None),
    })
}

fn provides_samples(session: &Session) -> bool {
    let provided = (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0) as u32;
    (session.output_info.dwFlags & provided) != 0
}

fn allocate_output_sample(size: u32) -> WinResult<IMFSample> {
    // SAFETY: the buffer is created with a non-zero capacity and added to a fresh sample.
    unsafe {
        let buffer = MFCreateMemoryBuffer(size.max(1))?;
        let sample = MFCreateSample()?;
        sample.AddBuffer(&buffer)?;
        Ok(sample)
    }
}

/// Takes ownership of the sample the MFT handed back, and releases the unused event collection.
pub(super) fn take_sample(mut buffer: MFT_OUTPUT_DATA_BUFFER) -> Option<IMFSample> {
    // SAFETY: the MFT is finished with the buffer, so this takes the reference it returned and nothing else reads it.
    let sample = unsafe { ManuallyDrop::take(&mut buffer.pSample) };
    // SAFETY: pEvents is never read again, so releasing it once here is the only release.
    unsafe { ManuallyDrop::drop(&mut buffer.pEvents) };
    sample
}

pub(super) fn read_sample(sample: &IMFSample) -> WinResult<EncodedBytes> {
    // SAFETY: the bytes are read between Lock and Unlock, while the buffer keeps them alive.
    unsafe {
        let hundred_nanoseconds = sample.GetSampleTime()?;
        let buffer = sample.ConvertToContiguousBuffer()?;
        let mut data = null_mut();
        let mut length = 0u32;
        buffer.Lock(&mut data, None, Some(&mut length))?;
        let annexb = if data.is_null() { Vec::new() } else { std::slice::from_raw_parts(data, length as usize).to_vec() };
        buffer.Unlock()?;
        Ok(EncodedBytes { annexb, hundred_nanoseconds })
    }
}

/// The MFT offers its new output type through the available-type list; accepting the first offer is the renegotiation.
pub(super) fn renegotiate_output(session: &Session) -> WinResult<()> {
    // SAFETY: stream 0 exists, and the type it returns is a live interface we pass straight back.
    unsafe {
        let available = session.transform.GetOutputAvailableType(0, 0)?;
        session.transform.SetOutputType(0, &available, 0)
    }
}
