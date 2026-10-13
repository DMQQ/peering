//! Lists the adapters through `GetAdaptersAddresses`. Unverified: written against the `windows` 0.58 API and not run on Windows.

use windows::Win32::NetworkManagement::IpHelper::{
    GetAdaptersAddresses, GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER, GAA_FLAG_SKIP_MULTICAST, IP_ADAPTER_ADDRESSES_LH,
};

use super::Adapter;

const AF_UNSPEC: u32 = 0;
const ERROR_BUFFER_OVERFLOW: u32 = 111;
const NO_ERROR: u32 = 0;
/// The list can grow between asking for its size and reading it.
const ATTEMPTS: usize = 3;

/// Every adapter the system lists, or none when the call fails.
pub fn adapter_addresses() -> Vec<Adapter> {
    let flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    let mut size = 15 * 1024u32;
    for _ in 0..ATTEMPTS {
        // Eight byte units, so the buffer is aligned for the structures written into it.
        let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
        let head = buffer.as_mut_ptr().cast::<IP_ADAPTER_ADDRESSES_LH>();
        // SAFETY: `head` points at `size` writable bytes aligned for IP_ADAPTER_ADDRESSES_LH, and `size` is updated in place.
        let status = unsafe { GetAdaptersAddresses(AF_UNSPEC, flags, None, Some(head), &mut size) };
        match status {
            NO_ERROR => return collect(head),
            ERROR_BUFFER_OVERFLOW => {}
            _ => return Vec::new(),
        }
    }
    Vec::new()
}

fn collect(head: *const IP_ADAPTER_ADDRESSES_LH) -> Vec<Adapter> {
    let mut adapters = Vec::new();
    let mut current = head;
    while !current.is_null() {
        // SAFETY: the list was written by GetAdaptersAddresses into a buffer that outlives this walk, and each Next is
        // either null or the next entry inside that buffer.
        let entry = unsafe { &*current };
        let length = (entry.PhysicalAddressLength as usize).min(entry.PhysicalAddress.len());
        adapters.push(Adapter { interface_type: entry.IfType, physical_address: entry.PhysicalAddress[..length].to_vec() });
        current = entry.Next;
    }
    adapters
}
