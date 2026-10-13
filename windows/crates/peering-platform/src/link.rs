//! The hand-off of a captured texture from the capture to the encoder, and the decisions the encoder makes from it.
//! Generic over the device and texture types, so the rules run on any OS with stand-in handles.

use peering_wire::quality::even_size;

use crate::handoff::FrameHandoff;

/// One adapter's LUID as a single key. Devices on the same adapter share it.
pub type AdapterKey = u64;

pub fn pack_luid(high_part: i32, low_part: u32) -> AdapterKey {
    (u64::from(high_part as u32) << 32) | u64::from(low_part)
}

/// Which D3D device a capture runs on: the adapter that owns it, and how many devices that capture has created. A device
/// created again after a removal or a reset sits on the same adapter, but nothing made on the old one works on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceKey {
    pub adapter: AdapterKey,
    pub generation: u64,
}

/// The device the capture runs on.
#[derive(Debug, Clone)]
pub struct BoundDevice<D> {
    pub key: DeviceKey,
    pub device: D,
}

/// The device of the running capture and the newest frame it acquired. A frame belongs to the device it came from, so
/// binding a different device drops it.
#[derive(Debug)]
pub struct FrameLink<D, T> {
    device: Option<BoundDevice<D>>,
    frame: Option<FrameHandoff<T>>,
}

impl<D, T> Default for FrameLink<D, T> {
    fn default() -> Self {
        Self { device: None, frame: None }
    }
}

impl<D, T> FrameLink<D, T> {
    pub fn bind(&mut self, device: Option<BoundDevice<D>>) {
        let same_device = self.device.as_ref().map(|bound| bound.key) == device.as_ref().map(|bound| bound.key);
        if !same_device {
            self.frame = None;
        }
        self.device = device;
    }

    pub fn device(&self) -> Option<&BoundDevice<D>> {
        self.device.as_ref()
    }

    pub fn put_frame(&mut self, frame: FrameHandoff<T>) {
        self.frame = Some(frame);
    }

    pub fn take_frame(&mut self) -> Option<FrameHandoff<T>> {
        self.frame.take()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Binding {
    /// The encoder already runs on this device.
    Reuse,
    /// The encoder must be opened again on the device it is given now.
    Rebind,
}

pub fn binding_for(bound: Option<DeviceKey>, device: DeviceKey) -> Binding {
    if bound == Some(device) {
        Binding::Reuse
    } else {
        Binding::Rebind
    }
}

/// The encode size a captured frame needs, when it differs from the size the encoder runs at. `None` means keep going.
pub fn resize_for(configured: Option<(u32, u32)>, captured: (u32, u32)) -> Option<(u32, u32)> {
    let wanted = even_size(captured.0, captured.1);
    (configured != Some(wanted)).then_some(wanted)
}

#[cfg(test)]
mod tests;
