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
pub const RELAY_CLOCK_SKEW: &str = "Relay refused: check the clock";
pub const RELAY_CLOCK_SKEW_PROBLEM: &str = "The relay refused this PC because its clock is more than a few minutes off. Turn on Set time automatically in Windows Settings, under Time & language, Date & time.";
pub const NEEDS_ATTENTION: &str = "Needs attention";
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
pub const RELAY_ENABLED: &str = "Reach this PC away from home through the relay";
pub const TERMINAL_HOOKS: &str = "Send Claude Code approvals to my phone";
pub const TERMINAL_HOOKS_HINT: &str = "Adds hooks to the Claude Code settings file. Turning this off takes them out again.";
pub const FIX_FIREWALL: &str = "Fix firewall";
pub const FIREWALL_HINT: &str = "Windows asks once for permission to let phones reach this PC. This works on networks Windows calls Private: if this one is Public, switch it to Private in Windows settings.";
pub const FIREWALL_REQUESTED: &str = "Approve the Windows prompt to add the firewall rule.";
pub const FIREWALL_APPLIED: &str = "The firewall rule is in place.";
pub const FRAME_RATE_HEADING: &str = "Frame rate";
pub const FRAME_RATE_NOTE: &str = "A phone can still ask for its own frame rate.";

pub const PRIVACY_MODE_UNAVAILABLE: &str = "Privacy mode is not available on this PC.";
pub const DESKTOPS_UNAVAILABLE: &str = "This PC cannot switch desktops from the phone.";
pub const WINDOW_ACTIONS_UNAVAILABLE: &str = "This PC cannot close or move windows from the phone yet.";
pub const LAUNCH_UNAVAILABLE: &str = "This PC cannot open apps from the phone yet.";
pub const MOSAIC_UNAVAILABLE: &str = "This PC cannot show several screens at once.";

pub const CLIPBOARD_WRITE_FAILED: &str = "This PC could not put that on its clipboard.";

pub const HOOKS_NO_RANDOM: &str = "Claude Code hooks could not start: this PC gave no random number for their access token.";

pub fn hooks_could_not_listen(reason: &str) -> String {
    format!("Claude Code hooks could not start: Peering could not listen for them ({reason}).")
}

pub fn hooks_could_not_install(reason: &str) -> String {
    format!("Claude Code hooks were not set up: {reason}.")
}

pub fn hooks_could_not_remove(reason: &str) -> String {
    format!("Claude Code hooks were turned off, but Peering could not take them out of Claude Code's settings: {reason}.")
}

pub fn settings_not_saved(reason: &str) -> String {
    format!("Settings could not be saved ({reason}), so they are lost when Peering Host closes.")
}

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

pub const PASS_HUNG_PREFIX: &str = "The host has stopped responding";

pub fn pass_hung(seconds: f64) -> String {
    format!("{PASS_HUNG_PREFIX} for {seconds:.0} s, usually a stuck video encoder or graphics driver. Quit and start it again if it does not recover.")
}

pub fn video_abandoned(seconds: f64) -> String {
    format!("The video encoder did not answer for {seconds:.0} s, so the host dropped it and is starting the screen capture again. If this repeats, update the graphics driver.")
}

pub fn capture_recovering(reason: &str) -> String {
    format!("Screen capture failed ({reason}). The host is trying again.")
}

pub fn relay_task_stopped(reason: &str) -> String {
    format!("The relay connection stopped ({reason}). Phones away from this network cannot connect until Peering Host is restarted.")
}

pub const RESET_PAIRED_DEVICES: &str = "Reset paired devices";
pub const RESET_PAIRED_DEVICES_WARNING: &str = "This starts an empty list. Every phone has to be paired again. The unreadable list is kept aside as pairedDevices-bad.";
pub const RESET_CONFIRM: &str = "Reset";
pub const RESET_CANCEL: &str = "Cancel";

pub fn paired_list_reset_failed(outcome: peering_core::paired_list::ResetOutcome) -> String {
    use peering_core::paired_list::ResetOutcome;
    let reason = match outcome {
        ResetOutcome::BackupFailed => "a copy of the unreadable list could not be kept, so nothing was changed",
        ResetOutcome::ReplaceFailed => "the new list could not be written, so the old one is still in place",
        ResetOutcome::ReadFailed => "the stored list could not be read at all",
        ResetOutcome::NotNeeded => "the stored list reads fine now, so restart Peering Host to load it",
        ResetOutcome::Done | ResetOutcome::NothingStored => "nothing needed resetting",
    };
    format!("The list of paired phones was not reset: {reason}. Pairing and forgetting stay paused.")
}

pub fn paired_list_unreadable(copy_kept: bool) -> String {
    let kept = if copy_kept {
        "A copy was kept as pairedDevices-bad."
    } else {
        "A copy could not be kept."
    };
    format!(
        "The list of paired phones could not be read, so pairing and forgetting are paused to protect it. {kept} Use Reset paired devices in the window to start over."
    )
}
