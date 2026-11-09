//! Lists the adapters through `GetAdaptersAddresses`. Unverified: written against the `windows` 0.58 API and not run on Windows.

use std::net::Ipv4Addr;

use windows::Win32::NetworkManagement::IpHelper::{
    GetAdaptersAddresses, GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER, GAA_FLAG_SKIP_MULTICAST, IP_ADAPTER_ADDRESSES_LH,
    IP_ADAPTER_UNICAST_ADDRESS_LH,
};
use windows::Win32::NetworkManagement::Ndis::IfOperStatusUp;
use windows::Win32::Networking::WinSock::SOCKADDR_IN;

use super::Adapter;

const AF_UNSPEC: u32 = 0;
const AF_INET: u16 = 2;
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
        adapters.push(Adapter {
            interface_type: entry.IfType,
            physical_address: entry.PhysicalAddress[..length].to_vec(),
            label: label(entry),
            up: entry.OperStatus == IfOperStatusUp,
            ipv4: ipv4_addresses(entry.FirstUnicastAddress),
        });
        current = entry.Next;
    }
    adapters
}

fn label(entry: &IP_ADAPTER_ADDRESSES_LH) -> String {
    // SAFETY: both strings are null terminated and live in the buffer that holds `entry`, or are null.
    let (name, description) = unsafe {
        (
            entry.FriendlyName.to_string().unwrap_or_default(),
            entry.Description.to_string().unwrap_or_default(),
        )
    };
    format!("{name} {description}")
}

fn ipv4_addresses(first: *const IP_ADAPTER_UNICAST_ADDRESS_LH) -> Vec<Ipv4Addr> {
    let mut addresses = Vec::new();
    let mut current = first;
    while !current.is_null() {
        // SAFETY: the unicast list lives in the same buffer as the adapter, and each Next is null or the next entry in it.
        let unicast = unsafe { &*current };
        let socket = unicast.Address.lpSockaddr;
        // SAFETY: a non-null sockaddr points at storage at least as large as its family says, and AF_INET means SOCKADDR_IN.
        if !socket.is_null() && unsafe { (*socket).sa_family.0 } == AF_INET {
            let v4 = unsafe { &*socket.cast::<SOCKADDR_IN>() };
            addresses.push(Ipv4Addr::from(u32::from_be(unsafe { v4.sin_addr.S_un.S_addr })));
        }
        current = unicast.Next;
    }
    addresses
}
