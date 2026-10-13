//! The hardware addresses a phone sends a Wake-on-LAN packet to. Which adapters count is decided here and tested on any OS;
//! `addresses/sys.rs` lists the adapters.

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
        Adapter { interface_type, physical_address: address.to_vec() }
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
