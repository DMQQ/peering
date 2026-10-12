//! The D3D11 device a capture runs on. The converter and the encoder must use this same device, because the textures
//! the capture acquires belong to it.

use windows::Win32::Foundation::LUID;
use windows::Win32::Graphics::Direct3D11::{ID3D11Device, ID3D11DeviceContext};

use std::sync::atomic::{AtomicU64, Ordering};

use crate::link::{pack_luid, AdapterKey, DeviceKey};

static GENERATIONS: AtomicU64 = AtomicU64::new(0);

#[derive(Clone)]
pub struct GpuContext {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    pub adapter: AdapterKey,
    /// Distinguishes this device from every other one created in the process, including one on the same adapter.
    pub generation: u64,
}

impl GpuContext {
    pub fn new(device: ID3D11Device, context: ID3D11DeviceContext, adapter_luid: LUID) -> Self {
        Self {
            device,
            context,
            adapter: pack_luid(adapter_luid.HighPart, adapter_luid.LowPart),
            generation: GENERATIONS.fetch_add(1, Ordering::Relaxed),
        }
    }

    pub fn key(&self) -> DeviceKey {
        DeviceKey { adapter: self.adapter, generation: self.generation }
    }
}
