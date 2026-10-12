//! Host settings and their line based `key=value` text form.

pub const DEFAULT_PORT: u16 = 51515;
pub const DEFAULT_FRAME_RATE: u32 = 60;
pub const ALLOWED_FRAME_RATES: [u32; 3] = [15, 30, 60];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostSettings {
    pub port: u16,
    pub frame_rate: u32,
    pub start_at_login: bool,
    pub relay_enabled: bool,
    pub device_name: String,
}

impl HostSettings {
    pub fn default_for(device_name: impl Into<String>) -> Self {
        Self {
            port: DEFAULT_PORT,
            frame_rate: DEFAULT_FRAME_RATE,
            start_at_login: true,
            relay_enabled: true,
            device_name: device_name.into(),
        }
    }

    /// Snaps the frame rate to the nearest allowed value (a tie goes to the lower rate) and replaces port 0 with the default.
    pub fn validated(self) -> Self {
        let port = if self.port == 0 { DEFAULT_PORT } else { self.port };
        Self {
            port,
            frame_rate: snap_frame_rate(self.frame_rate),
            ..self
        }
    }

    /// One `key=value` pair per line. Line breaks in the device name become spaces, since a line is the unit of the format.
    pub fn to_text(&self) -> String {
        let device_name = self.device_name.replace(['\r', '\n'], " ");
        format!(
            "port={}\nframeRate={}\nstartAtLogin={}\nrelayEnabled={}\ndeviceName={}\n",
            self.port, self.frame_rate, self.start_at_login, self.relay_enabled, device_name
        )
    }

    /// Reads the text form. Unknown keys are ignored, and a value that does not parse or is out of range takes the default.
    /// A later line with the same key wins. `default_device_name` fills in a missing or empty device name.
    pub fn from_text(text: &str, default_device_name: &str) -> Self {
        let mut settings = Self::default_for(default_device_name);
        for line in text.lines() {
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            apply_entry(&mut settings, key.trim(), value);
        }
        settings
    }
}

fn apply_entry(settings: &mut HostSettings, key: &str, value: &str) {
    let defaults = HostSettings::default_for(String::new());
    match key {
        "port" => settings.port = parse_port(value).unwrap_or(defaults.port),
        "frameRate" => settings.frame_rate = parse_frame_rate(value).unwrap_or(defaults.frame_rate),
        "startAtLogin" => settings.start_at_login = parse_bool(value).unwrap_or(defaults.start_at_login),
        "relayEnabled" => settings.relay_enabled = parse_bool(value).unwrap_or(defaults.relay_enabled),
        "deviceName" if !value.trim().is_empty() => settings.device_name = value.to_owned(),
        _ => {}
    }
}

fn parse_port(value: &str) -> Option<u16> {
    value.trim().parse::<u16>().ok().filter(|port| *port != 0)
}

fn parse_frame_rate(value: &str) -> Option<u32> {
    value
        .trim()
        .parse::<u32>()
        .ok()
        .filter(|rate| ALLOWED_FRAME_RATES.contains(rate))
}

fn parse_bool(value: &str) -> Option<bool> {
    match value.trim() {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

/// The allowed rate nearest to `requested`; halfway values take the lower rate.
pub fn snap_frame_rate(requested: u32) -> u32 {
    ALLOWED_FRAME_RATES
        .into_iter()
        .min_by_key(|allowed| allowed.abs_diff(requested))
        .unwrap_or(DEFAULT_FRAME_RATE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_the_documented_values() {
        let settings = HostSettings::default_for("Office PC");
        assert_eq!(settings.port, 51515);
        assert_eq!(settings.frame_rate, 60);
        assert!(settings.start_at_login);
        assert!(settings.relay_enabled);
        assert_eq!(settings.device_name, "Office PC");
    }

    #[test]
    fn allowed_frame_rates_are_kept_as_they_are() {
        for rate in ALLOWED_FRAME_RATES {
            let settings = HostSettings { frame_rate: rate, ..HostSettings::default_for("PC") };
            assert_eq!(settings.validated().frame_rate, rate);
        }
    }

    #[test]
    fn other_frame_rates_snap_to_the_nearest_allowed_one() {
        let snapped = |rate: u32| HostSettings { frame_rate: rate, ..HostSettings::default_for("PC") }.validated().frame_rate;
        assert_eq!(snapped(0), 15);
        assert_eq!(snapped(20), 15);
        assert_eq!(snapped(40), 30);
        assert_eq!(snapped(50), 60);
        assert_eq!(snapped(1000), 60);
    }

    #[test]
    fn a_frame_rate_halfway_between_two_allowed_values_takes_the_lower() {
        let settings = HostSettings { frame_rate: 45, ..HostSettings::default_for("PC") };
        assert_eq!(settings.validated().frame_rate, 30);
    }

    #[test]
    fn port_zero_is_replaced_by_the_default_and_other_ports_are_kept() {
        let zero = HostSettings { port: 0, ..HostSettings::default_for("PC") };
        assert_eq!(zero.validated().port, 51515);
        let custom = HostSettings { port: 40000, ..HostSettings::default_for("PC") };
        assert_eq!(custom.validated().port, 40000);
    }

    #[test]
    fn settings_survive_a_text_round_trip() {
        let settings = HostSettings {
            port: 40000,
            frame_rate: 30,
            start_at_login: false,
            relay_enabled: false,
            device_name: "Den = main, PC".to_owned(),
        };
        assert_eq!(HostSettings::from_text(&settings.to_text(), "fallback"), settings);
    }

    #[test]
    fn a_line_break_in_the_device_name_is_written_as_a_space() {
        let settings = HostSettings::default_for("first\nsecond");
        let parsed = HostSettings::from_text(&settings.to_text(), "fallback");
        assert_eq!(parsed.device_name, "first second");
    }

    #[test]
    fn garbage_and_bad_values_fall_back_to_the_defaults() {
        let text = "no equals sign\n=\nport=abc\nframeRate=45\nstartAtLogin=maybe\nrelayEnabled=\ndeviceName=   \n";
        assert_eq!(HostSettings::from_text(text, "PC"), HostSettings::default_for("PC"));
    }

    #[test]
    fn empty_input_gives_the_defaults() {
        assert_eq!(HostSettings::from_text("", "Laptop"), HostSettings::default_for("Laptop"));
    }

    #[test]
    fn port_zero_in_text_is_the_default_port() {
        let parsed = HostSettings::from_text("port=0", "PC");
        assert_eq!(parsed.port, 51515);
    }

    #[test]
    fn unknown_keys_are_ignored_and_known_keys_are_read() {
        let text = "future=1\nport=2000\nframeRate=30\nstartAtLogin=false\n";
        let parsed = HostSettings::from_text(text, "PC");
        assert_eq!(parsed.port, 2000);
        assert_eq!(parsed.frame_rate, 30);
        assert!(!parsed.start_at_login);
        assert!(parsed.relay_enabled);
    }

    #[test]
    fn a_later_line_with_the_same_key_wins() {
        let parsed = HostSettings::from_text("port=2000\nport=3000\n", "PC");
        assert_eq!(parsed.port, 3000);
    }
}
