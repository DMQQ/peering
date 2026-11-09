//! The hardware addresses a phone sends a Wake-on-LAN packet to, and the IP addresses the host must not announce. Which
//! adapters count is decided here and tested on any OS; `addresses/sys.rs` lists the adapters.

use std::net::{IpAddr, Ipv4Addr};

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::adapter_addresses;

/// `IF_TYPE_ETHERNET_CSMACD`.
const ETHERNET: u32 = 6;
/// `IF_TYPE_IEEE80211`.
const WIFI: u32 = 71;

/// One network adapter as the operating system reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Adapter {
    pub interface_type: u32,
    pub physical_address: Vec<u8>,
    /// The friendly name and the driver description, which is where a VPN or virtual switch gives itself away.
    pub label: String,
    pub up: bool,
    pub ipv4: Vec<Ipv4Addr>,
}

/// Name fragments of adapters a phone on the Wi-Fi cannot reach, which Windows still reports as Ethernet.
const VIRTUAL_MARKERS: [&str; 22] = [
    "vethernet", "hyper-v", "virtualbox", "vmware", "vmnet", "wsl", "docker", "tap-windows", "tap-", "wintun", "wireguard",
    "openvpn", "nordlynx", "tailscale", "zerotier", "hamachi", "radmin", "anyconnect", "fortinet", "vpn", "npcap", "loopback",
];

fn is_reachable_from_lan(adapter: &Adapter) -> bool {
    if !adapter.up || !matches!(adapter.interface_type, ETHERNET | WIFI) {
        return false;
    }
    let label = adapter.label.to_lowercase();
    !VIRTUAL_MARKERS.iter().any(|marker| label.contains(marker))
}

/// The IPv4 addresses the host must leave out of its mDNS record: every address of an adapter a phone on the same
/// network could not use. A client resolves one address from the record, so one unreachable address is a connect timeout.
/// An address that a reachable adapter also holds is kept.
pub fn addresses_to_hide(adapters: &[Adapter]) -> Vec<IpAddr> {
    let keep: Vec<Ipv4Addr> = adapters.iter().filter(|a| is_reachable_from_lan(a)).flat_map(|a| a.ipv4.clone()).collect();
    let mut hidden: Vec<IpAddr> = Vec::new();
    for address in adapters.iter().filter(|a| !is_reachable_from_lan(a)).flat_map(|a| a.ipv4.iter().copied()) {
        if !keep.contains(&address) && !hidden.contains(&IpAddr::V4(address)) {
            hidden.push(IpAddr::V4(address));
        }
    }
    hidden
}

/// `aa:bb:cc:dd:ee:ff` for a six byte address that is not all zeros, as the Mac host writes it.
pub fn format_address(bytes: &[u8]) -> Option<String> {
    if bytes.len() != 6 || bytes.iter().all(|byte| *byte == 0) {
        return None;
    }
    Some(bytes.iter().map(|byte| format!("{byte:02x}")).collect::<Vec<_>>().join(":"))
}

/// Ethernet and Wi-Fi adapters only (a tunnel or a loopback cannot be woken), each address once, in adapter order.
pub fn wake_addresses(adapters: &[Adapter]) -> Vec<String> {
    let mut addresses: Vec<String> = Vec::new();
    for adapter in adapters.iter().filter(|adapter| matches!(adapter.interface_type, ETHERNET | WIFI)) {
        if let Some(address) = format_address(&adapter.physical_address) {
            if !addresses.contains(&address) {
                addresses.push(address);
            }
        }
    }
    addresses
}

#[cfg(test)]
mod tests {
    use super::*;

    fn adapter(interface_type: u32, address: &[u8]) -> Adapter {
        Adapter { interface_type, physical_address: address.to_vec(), label: String::new(), up: true, ipv4: Vec::new() }
    }

    fn networked(interface_type: u32, label: &str, up: bool, ipv4: &[[u8; 4]]) -> Adapter {
        Adapter {
            interface_type,
            physical_address: Vec::new(),
            label: label.to_owned(),
            up,
            ipv4: ipv4.iter().map(|octets| Ipv4Addr::from(*octets)).collect(),
        }
    }

    #[test]
    fn a_vpn_and_a_virtual_switch_are_hidden_and_the_lan_adapter_is_kept() {
        let adapters = [
            networked(71, "Wi-Fi", true, &[[192, 168, 1, 20]]),
            networked(6, "vEthernet (WSL)", true, &[[172, 20, 0, 1]]),
            networked(6, "NordLynx", true, &[[10, 5, 0, 2]]),
            networked(131, "Tunnel", true, &[[10, 9, 0, 2]]),
        ];
        let hidden = addresses_to_hide(&adapters);
        assert_eq!(hidden.len(), 3);
        assert!(!hidden.contains(&IpAddr::from([192, 168, 1, 20])));
        assert!(hidden.contains(&IpAddr::from([172, 20, 0, 1])));
        assert!(hidden.contains(&IpAddr::from([10, 5, 0, 2])));
    }

    #[test]
    fn an_adapter_that_is_down_is_hidden() {
        let hidden = addresses_to_hide(&[networked(6, "Ethernet", false, &[[169, 254, 3, 4]])]);
        assert_eq!(hidden, [IpAddr::from([169, 254, 3, 4])]);
    }

    #[test]
    fn an_address_a_lan_adapter_also_holds_is_never_hidden() {
        let adapters = [networked(6, "Ethernet", true, &[[10, 0, 0, 5]]), networked(6, "Corp VPN", true, &[[10, 0, 0, 5]])];
        assert!(addresses_to_hide(&adapters).is_empty());
    }

    #[test]
    fn an_address_is_lowercase_hex_pairs_joined_by_colons() {
        assert_eq!(format_address(&[0xAA, 0xBB, 0x0C, 0xDD, 0xEE, 0xFF]).as_deref(), Some("aa:bb:0c:dd:ee:ff"));
    }

    #[test]
    fn an_all_zero_or_wrong_length_address_is_not_one() {
        assert_eq!(format_address(&[0; 6]), None);
        assert_eq!(format_address(&[1, 2, 3]), None);
        assert_eq!(format_address(&[1; 8]), None);
    }

    #[test]
    fn ethernet_and_wifi_count_and_a_tunnel_does_not() {
        let adapters = [
            adapter(6, &[1, 2, 3, 4, 5, 6]),
            adapter(71, &[6, 5, 4, 3, 2, 1]),
            adapter(131, &[9, 9, 9, 9, 9, 9]),
            adapter(24, &[0; 6]),
        ];
        assert_eq!(wake_addresses(&adapters), ["01:02:03:04:05:06", "06:05:04:03:02:01"]);
    }

    #[test]
    fn an_address_two_adapters_share_is_listed_once() {
        let adapters = [adapter(6, &[1, 2, 3, 4, 5, 6]), adapter(6, &[1, 2, 3, 4, 5, 6])];
        assert_eq!(wake_addresses(&adapters), ["01:02:03:04:05:06"]);
    }
}
