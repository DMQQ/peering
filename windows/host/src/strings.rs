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

pub const PAIRING_TITLE: &str = "Pair a phone";
pub const NEEDS_HOSTING: &str = "Start hosting to pair a phone.";
pub const SCAN_TO_FIND_HOST: &str = "Scan this code on the phone to find this PC.";
pub const CODE_HEADING: &str = "Check the same six digits appear on the phone";
pub const RELAY_PAIRING_NOTE: &str = "This phone is pairing through the relay.";
pub const CODE_TOO_LONG: &str = "This code is too long to draw.";
pub const APPROVE: &str = "Approve";
pub const DECLINE: &str = "Decline";
pub const FORGET: &str = "Forget";
pub const APPROVALS_HEADING: &str = "Waiting for approval";
pub const DEVICES_HEADING: &str = "Paired phones";
pub const NO_DEVICES: &str = "No paired phones yet.";

pub const START_AT_LOGIN: &str = "Start at login";
pub const FIX_FIREWALL: &str = "Fix firewall";
pub const FIREWALL_HINT: &str = "Windows asks once for permission to let phones reach this PC. This works on networks Windows calls Private: if this one is Public, switch it to Private in Windows settings.";
pub const FIREWALL_REQUESTED: &str = "Approve the Windows prompt to add the firewall rule.";
pub const FRAME_RATE_HEADING: &str = "Frame rate";
pub const FRAME_RATE_NOTE: &str = "A phone can still ask for its own frame rate.";

pub fn approval_prompt(client_name: &str) -> String {
    format!("{client_name} wants to pair without scanning the code")
}

pub fn pairing_with(client_name: &str) -> String {
    format!("{client_name} is pairing")
}

pub fn last_seen(seconds_ago: u64) -> String {
    match seconds_ago {
        0..=59 => "Seen just now".to_owned(),
        60..=3599 => format!("Seen {} min ago", seconds_ago / 60),
        3600..=86_399 => format!("Seen {} h ago", seconds_ago / 3600),
        _ => format!("Seen {} days ago", seconds_ago / 86_400),
    }
}

pub fn firewall_refused(reason: &str) -> String {
    format!("The firewall rule was not added: {reason}")
}

pub fn autostart_failed(reason: &str) -> String {
    format!("Start at login could not be changed: {reason}")
}

pub fn frame_rate_label(fps: u32) -> String {
    format!("{fps} fps")
}

pub fn host_stopped(reason: &str) -> String {
    format!("Host stopped: {reason}")
}

pub fn connected_clients(count: usize) -> String {
    match count {
        0 => "No phone connected".to_owned(),
        1 => "1 phone connected".to_owned(),
        count => format!("{count} phones connected"),
    }
}
