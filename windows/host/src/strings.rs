//! Every sentence the user reads. The tray and the window take their text from here, so wording changes in one place.

pub const START_HOSTING: &str = "Start hosting";
pub const STOP_HOSTING: &str = "Stop hosting";
pub const SHOW_PAIRING_CODE: &str = "Show pairing code";
pub const DEVICES: &str = "Devices";
pub const SETTINGS: &str = "Settings";
pub const QUIT: &str = "Quit";

pub const HOSTING_ON: &str = "Hosting";
pub const HOSTING_OFF: &str = "Not hosting";
pub const RELAY_OFF: &str = "Relay off";
pub const RELAY_CONNECTING: &str = "Relay connecting";
pub const RELAY_REGISTERED: &str = "Relay connected";
pub const RELAY_RETRYING: &str = "Relay retrying";
pub const TOOLTIP: &str = "Peering Host";

pub fn connected_clients(count: usize) -> String {
    match count {
        0 => "No phone connected".to_owned(),
        1 => "1 phone connected".to_owned(),
        count => format!("{count} phones connected"),
    }
}
