//! Media Foundation calls behind the encoder: startup, the D3D11 device manager, enumerating and opening H.264 MFTs, and
//! their type and codec property setup. Sample handling is in `sys/io.rs`.

pub(super) mod io;

use super::candidates::{rank_candidates, CandidateInfo};
use super::settings::EncoderSettings;
use std::ffi::c_void;
use windows::core::{Interface, Result as WinResult, GUID};
use windows::Win32::Foundation::E_FAIL;
use windows::Win32::Graphics::Direct3D11::ID3D11Device;
use windows::Win32::Media::MediaFoundation::{
    eAVEncCommonRateControlMode_CBR, eAVEncH264VProfile_Main, CODECAPI_AVEncCommonMeanBitRate,
    CODECAPI_AVEncCommonRateControlMode, CODECAPI_AVEncMPVDefaultBPictureCount, CODECAPI_AVEncMPVGOPSize,
    CODECAPI_AVEncVideoForceKeyFrame, CODECAPI_AVLowLatencyMode, ICodecAPI, IMFActivate, IMFDXGIDeviceManager,
    IMFMediaType, IMFTransform, MFCreateDXGIDeviceManager, MFCreateMediaType, MFMediaType_Video, MFShutdown, MFStartup,
    MFTEnumEx, MFVideoFormat_H264, MFVideoFormat_NV12, MFVideoInterlace_Progressive, MFT_CATEGORY_VIDEO_ENCODER,
    MFT_ENUM_FLAG, MFT_ENUM_FLAG_ASYNCMFT, MFT_ENUM_FLAG_HARDWARE, MFT_ENUM_FLAG_LOCALMFT, MFT_ENUM_FLAG_SORTANDFILTER,
    MFT_ENUM_FLAG_SYNCMFT, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, MFT_MESSAGE_NOTIFY_START_OF_STREAM,
    MFT_MESSAGE_SET_D3D_MANAGER, MFT_OUTPUT_STREAM_INFO, MFT_REGISTER_TYPE_INFO, MFSTARTUP_FULL, MF_MT_AVG_BITRATE,
    MF_MT_FRAME_RATE, MF_MT_FRAME_SIZE, MF_MT_INTERLACE_MODE, MF_MT_MAJOR_TYPE, MF_MT_MPEG2_PROFILE, MF_MT_SUBTYPE,
    MF_SA_D3D11_AWARE, MF_TRANSFORM_ASYNC_UNLOCK, MF_VERSION,
};
use windows::Win32::System::Com::CoTaskMemFree;
use windows::core::VARIANT;

/// An opened encoder. `settings` is the current target; the bitrate can change while the session runs.
pub(super) struct Session {
    pub(super) transform: IMFTransform,
    pub(super) codec: ICodecAPI,
    pub(super) settings: EncoderSettings,
    pub(super) output_info: MFT_OUTPUT_STREAM_INFO,
}

pub(super) fn startup() -> WinResult<()> {
    // SAFETY: MFStartup has no pointer arguments; every call is paired with shutdown by the encoder that made it.
    unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) }
}

pub(super) fn shutdown() {
    // SAFETY: pairs with the startup in `startup`. A failed shutdown leaves nothing to undo, so its result is dropped.
    let _shutdown = unsafe { MFShutdown() };
}

/// The manager is reset to `device`, so every texture the encoder receives must come from that device.
pub(super) fn device_manager(device: &ID3D11Device) -> WinResult<IMFDXGIDeviceManager> {
    let mut token = 0u32;
    let mut created = None;
    // SAFETY: both out parameters point at live locals for the duration of the call.
    unsafe { MFCreateDXGIDeviceManager(&mut token, &mut created)? };
    let manager = created.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
    // SAFETY: the manager and device are live COM objects; the token is the one just issued.
    unsafe { manager.ResetDevice(device, token)? };
    Ok(manager)
}

/// Tries the ranked encoders and returns the first that opens. `Ok(None)` means none could take these settings.
pub(super) fn open(manager: &IMFDXGIDeviceManager, settings: EncoderSettings) -> WinResult<Option<Session>> {
    let candidates = enumerate()?;
    let infos: Vec<CandidateInfo> = candidates.iter().map(|candidate| candidate.info).collect();
    for index in rank_candidates(&infos) {
        let candidate = &candidates[index];
        if !candidate.info.d3d11_aware {
            continue;
        }
        // A candidate that fails to open is skipped; the next one in rank order is the fallback.
        if let Ok(session) = open_candidate(&candidate.activate, manager, settings) {
            return Ok(Some(session));
        }
    }
    Ok(None)
}

struct Activated {
    info: CandidateInfo,
    activate: IMFActivate,
}

fn enumerate() -> WinResult<Vec<Activated>> {
    let hardware = MFT_ENUM_FLAG(MFT_ENUM_FLAG_HARDWARE.0 | MFT_ENUM_FLAG_SORTANDFILTER.0);
    let mut found = enumerate_flags(hardware, true)?;
    let software = MFT_ENUM_FLAG(
        MFT_ENUM_FLAG_SYNCMFT.0 | MFT_ENUM_FLAG_ASYNCMFT.0 | MFT_ENUM_FLAG_LOCALMFT.0 | MFT_ENUM_FLAG_SORTANDFILTER.0,
    );
    found.extend(enumerate_flags(software, false)?);
    Ok(found)
}

fn enumerate_flags(flags: MFT_ENUM_FLAG, hardware: bool) -> WinResult<Vec<Activated>> {
    let output = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_H264 };
    let mut list: *mut Option<IMFActivate> = std::ptr::null_mut();
    let mut count = 0u32;
    // SAFETY: on success MFTEnumEx allocates `list` with CoTaskMemAlloc and sets `count` initialised entries.
    unsafe { MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, flags, None, Some(&output as *const _), &mut list, &mut count)? };
    let mut found = Vec::new();
    if list.is_null() {
        return Ok(found);
    }
    // SAFETY: `list` points at `count` entries that MFTEnumEx initialised and nothing else aliases.
    let slots = unsafe { std::slice::from_raw_parts_mut(list, count as usize) };
    for slot in slots.iter_mut() {
        if let Some(activate) = slot.take() {
            // SAFETY: the attribute store belongs to the activation object; a missing value reads as not aware.
            let d3d11_aware = unsafe { activate.GetUINT32(&MF_SA_D3D11_AWARE) }.unwrap_or(0) != 0;
            found.push(Activated { info: CandidateInfo { hardware, d3d11_aware }, activate });
        }
    }
    // SAFETY: the array came from CoTaskMemAlloc, and its entries were taken out above.
    unsafe { CoTaskMemFree(Some(list as *const c_void)) };
    Ok(found)
}

fn open_candidate(activate: &IMFActivate, manager: &IMFDXGIDeviceManager, settings: EncoderSettings) -> WinResult<Session> {
    // SAFETY: the activation object is live and ActivateObject returns a new reference we own.
    let transform: IMFTransform = unsafe { activate.ActivateObject()? };
    allow_async_unlock(&transform)?;
    // SAFETY: the manager pointer stays valid because `manager` outlives the transform's use of it.
    unsafe { transform.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, manager.as_raw() as usize)? };
    let codec: ICodecAPI = transform.cast()?;
    configure_codec(&codec, settings)?;
    set_media_types(&transform, settings)?;
    // SAFETY: streaming notifications take no payload and are sent in the order the MFT requires.
    unsafe {
        transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
        transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
    }
    // SAFETY: stream 0 is the encoder's only output.
    let output_info = unsafe { transform.GetOutputStreamInfo(0)? };
    Ok(Session { transform, codec, settings, output_info })
}

fn allow_async_unlock(transform: &IMFTransform) -> WinResult<()> {
    // SAFETY: GetAttributes returns a reference-counted store. A synchronous encoder has none, which is not an error.
    if let Ok(attributes) = unsafe { transform.GetAttributes() } {
        // SAFETY: the key is a constant GUID and the value is a plain u32.
        unsafe { attributes.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1)? };
    }
    Ok(())
}

fn configure_codec(codec: &ICodecAPI, settings: EncoderSettings) -> WinResult<()> {
    set_property(codec, &CODECAPI_AVLowLatencyMode, VARIANT::from(true))?;
    set_property(codec, &CODECAPI_AVEncCommonRateControlMode, VARIANT::from(eAVEncCommonRateControlMode_CBR.0 as u32))?;
    set_property(codec, &CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(settings.bitrate_bps))?;
    // Best effort: an encoder that rejects these keeps its own keyframe interval and B-picture defaults.
    let _gop = set_property(codec, &CODECAPI_AVEncMPVGOPSize, VARIANT::from(settings.gop_size()));
    let _b_pictures = set_property(codec, &CODECAPI_AVEncMPVDefaultBPictureCount, VARIANT::from(0u32));
    Ok(())
}

fn set_media_types(transform: &IMFTransform, settings: EncoderSettings) -> WinResult<()> {
    let output = video_type(&MFVideoFormat_H264, settings)?;
    // SAFETY: the media type is a live object we just created; the profile and bitrate are plain values.
    unsafe {
        output.SetUINT32(&MF_MT_AVG_BITRATE, settings.bitrate_bps)?;
        output.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main.0 as u32)?;
        transform.SetOutputType(0, &output, 0)?;
    }
    // The output type must be set before the input type, as the encoder requires.
    let input = video_type(&MFVideoFormat_NV12, settings)?;
    // SAFETY: the input type is a live object we just created.
    unsafe { transform.SetInputType(0, &input, 0)? };
    Ok(())
}

fn video_type(subtype: &GUID, settings: EncoderSettings) -> WinResult<IMFMediaType> {
    // SAFETY: the media type is a fresh object; every key is a constant and every value a plain integer.
    unsafe {
        let media = MFCreateMediaType()?;
        media.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        media.SetGUID(&MF_MT_SUBTYPE, subtype)?;
        media.SetUINT64(&MF_MT_FRAME_SIZE, pack_pair(settings.width, settings.height))?;
        media.SetUINT64(&MF_MT_FRAME_RATE, pack_pair(settings.fps, 1))?;
        media.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        Ok(media)
    }
}

/// Media Foundation packs a size or a ratio as high word first in one u64.
fn pack_pair(high: u32, low: u32) -> u64 {
    (u64::from(high) << 32) | u64::from(low)
}

pub(super) fn set_bitrate(session: &Session, bitrate_bps: u32) -> WinResult<()> {
    set_property(&session.codec, &CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(bitrate_bps))
}

pub(super) fn force_keyframe(session: &Session) -> WinResult<()> {
    set_property(&session.codec, &CODECAPI_AVEncVideoForceKeyFrame, VARIANT::from(1u32))
}

fn set_property(codec: &ICodecAPI, key: &GUID, value: VARIANT) -> WinResult<()> {
    // SAFETY: the key and the value are live for the duration of the call, and SetValue copies what it needs.
    unsafe { codec.SetValue(key, &value) }
}
