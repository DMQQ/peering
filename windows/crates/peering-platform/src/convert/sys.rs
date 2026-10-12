//! D3D11 video processor blit from a BGRA texture into an NV12 texture of the encode size.

use std::mem::ManuallyDrop;
use std::ptr::null_mut;

use peering_wire::quality::even_size;
use windows::core::{Error, Interface, Result};
use windows::Win32::Foundation::{BOOL, E_FAIL};
use windows::Win32::Graphics::Direct3D11::{
    ID3D11Device, ID3D11Texture2D, ID3D11VideoContext, ID3D11VideoDevice, ID3D11VideoProcessor,
    ID3D11VideoProcessorEnumerator, ID3D11VideoProcessorInputView, ID3D11VideoProcessorOutputView,
    D3D11_BIND_RENDER_TARGET, D3D11_TEX2D_VPIV, D3D11_TEX2D_VPOV, D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT,
    D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE, D3D11_VIDEO_PROCESSOR_COLOR_SPACE, D3D11_VIDEO_PROCESSOR_CONTENT_DESC,
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC, D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0,
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC, D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0, D3D11_VIDEO_PROCESSOR_STREAM,
    D3D11_VIDEO_USAGE_PLAYBACK_NORMAL, D3D11_VPIV_DIMENSION_TEXTURE2D, D3D11_VPOV_DIMENSION_TEXTURE2D,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_NV12, DXGI_RATIONAL, DXGI_SAMPLE_DESC};

/// Colour space bit layout: YCbCr matrix at bit 2 (1 = BT.709), nominal range at bits 4 to 5.
const RGB_FULL_RANGE: u32 = 2 << 4;
const BT709_LIMITED_YCBCR: u32 = (1 << 2) | (1 << 4);

pub struct Nv12Converter {
    stage: Option<Stage>,
}

/// Everything built for one device and one input and output size. The device is held so its identity can be compared.
struct Stage {
    device: ID3D11Device,
    input_size: (u32, u32),
    output_size: (u32, u32),
    video_device: ID3D11VideoDevice,
    video_context: ID3D11VideoContext,
    enumerator: ID3D11VideoProcessorEnumerator,
    processor: ID3D11VideoProcessor,
    output_view: ID3D11VideoProcessorOutputView,
    output_texture: ID3D11Texture2D,
}

impl Nv12Converter {
    pub fn new() -> Self {
        Self { stage: None }
    }

    /// Converts `input` into an NV12 texture of `output_size`, rounded to even sides. The returned texture is reused by
    /// the next call, so the consumer must finish with it before converting again.
    pub fn convert(&mut self, input: &ID3D11Texture2D, output_size: (u32, u32)) -> Result<ID3D11Texture2D> {
        let input_size = texture_size(input)?;
        let output_size = even_size(output_size.0, output_size.1);
        let device = device_of(input)?;
        let reusable = self.stage.as_ref().is_some_and(|stage| {
            stage.input_size == input_size
                && stage.output_size == output_size
                && Interface::as_raw(&stage.device) == Interface::as_raw(&device)
        });
        if !reusable {
            self.stage = Some(Stage::build(device, input_size, output_size)?);
        }
        let stage = self.stage.as_ref().ok_or_else(|| Error::from(E_FAIL))?;
        stage.blit(input)?;
        Ok(stage.output_texture.clone())
    }
}

impl Stage {
    fn build(device: ID3D11Device, input_size: (u32, u32), output_size: (u32, u32)) -> Result<Self> {
        let video_device: ID3D11VideoDevice = device.cast()?;
        // SAFETY: the device is live; the call only returns a new reference to its immediate context.
        let immediate = unsafe { device.GetImmediateContext()? };
        let video_context: ID3D11VideoContext = immediate.cast()?;
        let content = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
            InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
            InputFrameRate: DXGI_RATIONAL { Numerator: 60, Denominator: 1 },
            InputWidth: input_size.0,
            InputHeight: input_size.1,
            OutputFrameRate: DXGI_RATIONAL { Numerator: 60, Denominator: 1 },
            OutputWidth: output_size.0,
            OutputHeight: output_size.1,
            Usage: D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
        };
        // SAFETY: `content` is a live description for the duration of each call.
        let enumerator = unsafe { video_device.CreateVideoProcessorEnumerator(&content)? };
        // SAFETY: the enumerator is live and processor index 0 is the one every device exposes.
        let processor = unsafe { video_device.CreateVideoProcessor(&enumerator, 0)? };
        let output_texture = create_nv12_texture(&device, output_size)?;
        let output_desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
            ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
            Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 } },
        };
        let mut output_view = None;
        // SAFETY: the texture, enumerator and description are live, and the out slot is valid.
        unsafe {
            video_device.CreateVideoProcessorOutputView(&output_texture, &enumerator, &output_desc, Some(&mut output_view))?
        };
        let output_view = output_view.ok_or_else(|| Error::from(E_FAIL))?;
        set_color_spaces(&video_context, &processor);
        Ok(Self {
            device,
            input_size,
            output_size,
            video_device,
            video_context,
            enumerator,
            processor,
            output_view,
            output_texture,
        })
    }

    fn blit(&self, input: &ID3D11Texture2D) -> Result<()> {
        let input_view = self.input_view(input)?;
        let mut streams = [D3D11_VIDEO_PROCESSOR_STREAM {
            Enable: BOOL::from(true),
            OutputIndex: 0,
            InputFrameOrField: 0,
            PastFrames: 0,
            FutureFrames: 0,
            ppPastSurfaces: null_mut(),
            pInputSurface: ManuallyDrop::new(Some(input_view)),
            ppFutureSurfaces: null_mut(),
            ppPastSurfacesRight: null_mut(),
            pInputSurfaceRight: ManuallyDrop::new(None),
            ppFutureSurfacesRight: null_mut(),
        }];
        // SAFETY: the processor, output view and stream array are live for the call. The stream's input view is
        // released below, once the blit no longer needs it.
        let result = unsafe { self.video_context.VideoProcessorBlt(&self.processor, &self.output_view, 0, &streams) };
        // SAFETY: the view was wrapped in ManuallyDrop above and is dropped exactly once, here.
        unsafe { ManuallyDrop::drop(&mut streams[0].pInputSurface) };
        result
    }

    fn input_view(&self, input: &ID3D11Texture2D) -> Result<ID3D11VideoProcessorInputView> {
        let desc = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
            FourCC: 0,
            ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
            Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPIV { MipSlice: 0, ArraySlice: 0 } },
        };
        let mut view = None;
        // SAFETY: the input texture and enumerator are live, and `view` is a valid out slot.
        unsafe { self.video_device.CreateVideoProcessorInputView(input, &self.enumerator, &desc, Some(&mut view))? };
        view.ok_or_else(|| Error::from(E_FAIL))
    }
}

fn set_color_spaces(context: &ID3D11VideoContext, processor: &ID3D11VideoProcessor) {
    let input = D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: RGB_FULL_RANGE };
    let output = D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: BT709_LIMITED_YCBCR };
    // SAFETY: both colour space descriptions are live locals read during the calls.
    unsafe {
        context.VideoProcessorSetStreamColorSpace(processor, 0, &input);
        context.VideoProcessorSetOutputColorSpace(processor, &output);
    }
}

fn create_nv12_texture(device: &ID3D11Device, size: (u32, u32)) -> Result<ID3D11Texture2D> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: size.0,
        Height: size.1,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_NV12,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32,
        CPUAccessFlags: 0,
        MiscFlags: 0,
    };
    let mut texture = None;
    // SAFETY: `desc` is live for the call and no initial data is supplied.
    unsafe { device.CreateTexture2D(&desc, None, Some(&mut texture))? };
    texture.ok_or_else(|| Error::from(E_FAIL))
}

fn texture_size(texture: &ID3D11Texture2D) -> Result<(u32, u32)> {
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    // SAFETY: `desc` is a live local that GetDesc fills in full.
    unsafe { texture.GetDesc(&mut desc) };
    Ok((desc.Width, desc.Height))
}

fn device_of(texture: &ID3D11Texture2D) -> Result<ID3D11Device> {
    // SAFETY: the texture is live; the call only returns a new reference to its device.
    unsafe { texture.GetDevice() }
}
