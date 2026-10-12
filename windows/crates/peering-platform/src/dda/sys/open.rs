//! Opens a duplication on the adapter that owns one monitor, which is the only adapter that can duplicate it on hybrid GPU laptops.

use windows::core::{Interface, Result};
use windows::Win32::Foundation::{E_FAIL, HMODULE};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION,
};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory1, IDXGIOutput, IDXGIOutput1, IDXGIOutputDuplication,
};

pub struct Session {
    /// Held only to keep the device alive while the duplication uses it.
    pub _device: ID3D11Device,
    pub duplication: IDXGIOutputDuplication,
}

pub fn open_session(device_name: &str) -> Result<Session> {
    let (adapter, output) = find_output(device_name)?.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
    let device = create_device(&adapter)?;
    // SAFETY: `output` is a live IDXGIOutput of the adapter the device was created on, so the duplication matches it.
    let duplication = unsafe { output.cast::<IDXGIOutput1>()?.DuplicateOutput(&device)? };
    Ok(Session { _device: device, duplication })
}

fn find_output(device_name: &str) -> Result<Option<(IDXGIAdapter1, IDXGIOutput)>> {
    // SAFETY: CreateDXGIFactory1 takes no pointers beyond the returned interface.
    let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1()? };
    let mut adapter_index = 0;
    // SAFETY: enumeration is read-only; it ends with DXGI_ERROR_NOT_FOUND, which stops the loop.
    while let Ok(adapter) = unsafe { factory.EnumAdapters1(adapter_index) } {
        if let Some(output) = find_output_on(&adapter, device_name)? {
            return Ok(Some((adapter, output)));
        }
        adapter_index += 1;
    }
    Ok(None)
}

fn find_output_on(adapter: &IDXGIAdapter1, device_name: &str) -> Result<Option<IDXGIOutput>> {
    let mut output_index = 0;
    // SAFETY: as in `find_output`, the loop ends with DXGI_ERROR_NOT_FOUND.
    while let Ok(output) = unsafe { adapter.EnumOutputs(output_index) } {
        // SAFETY: GetDesc only reads the live output.
        let desc = unsafe { output.GetDesc()? };
        let name_end = desc.DeviceName.iter().position(|&unit| unit == 0).unwrap_or(desc.DeviceName.len());
        if String::from_utf16_lossy(&desc.DeviceName[..name_end]).eq_ignore_ascii_case(device_name) {
            return Ok(Some(output));
        }
        output_index += 1;
    }
    Ok(None)
}

fn create_device(adapter: &IDXGIAdapter1) -> Result<ID3D11Device> {
    let mut device: Option<ID3D11Device> = None;
    // SAFETY: an explicit adapter requires DRIVER_TYPE_UNKNOWN; BGRA support is what desktop duplication textures need.
    unsafe {
        D3D11CreateDevice(
            adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            None,
        )?
    };
    device.ok_or_else(|| windows::core::Error::from(E_FAIL))
}
