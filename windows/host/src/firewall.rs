//! The inbound rule that lets phones reach the host on the local network. Changing the firewall needs elevation, so the
//! host starts a copy of itself with `--firewall-rule <port>` through ShellExecuteW "runas"; that copy applies the rule.
//! The builders are pure and tested natively. The Windows parts are unverified until run on Windows.

pub const RULE_NAME: &str = "Peering Host";
pub const HELPER_FLAG: &str = "--firewall-rule";

/// The netsh arguments for an inbound TCP rule on `port` for the executable at `exe_path`, on private networks only.
pub fn netsh_firewall_args(exe_path: &str, port: u16) -> Vec<String> {
    vec![
        "advfirewall".to_owned(),
        "firewall".to_owned(),
        "add".to_owned(),
        "rule".to_owned(),
        format!("name={RULE_NAME}"),
        "dir=in".to_owned(),
        "action=allow".to_owned(),
        "protocol=TCP".to_owned(),
        format!("localport={port}"),
        "profile=private".to_owned(),
        format!("program={exe_path}"),
    ]
}

/// The arguments that remove the rule before it is added again, so a changed port or path never leaves a stale rule.
pub fn netsh_delete_args() -> Vec<String> {
    vec!["advfirewall".to_owned(), "firewall".to_owned(), "delete".to_owned(), "rule".to_owned(), format!("name={RULE_NAME}")]
}

/// The port named by a `--firewall-rule <port>` request, if the arguments are one.
pub fn helper_port(arguments: &[String]) -> Option<u16> {
    let position = arguments.iter().position(|argument| argument == HELPER_FLAG)?;
    arguments.get(position + 1)?.parse().ok()
}

/// Joins arguments into one command line with the quoting Windows programs expect, for ShellExecuteW parameters.
pub fn command_line(arguments: &[String]) -> String {
    arguments.iter().map(|argument| quote_argument(argument)).collect::<Vec<_>>().join(" ")
}

fn quote_argument(argument: &str) -> String {
    if !argument.is_empty() && !argument.contains([' ', '\t', '"']) {
        return argument.to_owned();
    }
    let mut quoted = String::from("\"");
    let mut backslashes = 0usize;
    for character in argument.chars() {
        match character {
            '\\' => backslashes += 1,
            '"' => {
                quoted.extend(std::iter::repeat_n('\\', backslashes * 2 + 1));
                quoted.push('"');
                backslashes = 0;
            }
            _ => {
                quoted.extend(std::iter::repeat_n('\\', backslashes));
                quoted.push(character);
                backslashes = 0;
            }
        }
    }
    quoted.extend(std::iter::repeat_n('\\', backslashes * 2));
    quoted.push('"');
    quoted
}

#[cfg(windows)]
pub fn request_rule_elevated(exe_path: &std::path::Path, port: u16) -> std::io::Result<()> {
    use windows::core::HSTRING;
    use windows::Win32::UI::Shell::ShellExecuteW;
    use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;

    let parameters = command_line(&[HELPER_FLAG.to_owned(), port.to_string()]);
    // SAFETY: every string is a live HSTRING for the duration of the call, and no window handle is passed.
    let result = unsafe {
        ShellExecuteW(
            None,
            &HSTRING::from("runas"),
            &HSTRING::from(exe_path.to_string_lossy().as_ref()),
            &HSTRING::from(parameters),
            None,
            SW_HIDE,
        )
    };
    // ShellExecuteW reports success with a value above 32; anything at or below that is an error code, such as a refused prompt.
    if result.0 as isize > 32 {
        Ok(())
    } else {
        Err(std::io::Error::other("the firewall request was refused or could not start"))
    }
}

/// Replaces the host's inbound rule. Runs in the elevated copy started by `request_rule_elevated`.
#[cfg(windows)]
pub fn apply_rule(exe_path: &std::path::Path, port: u16) -> std::io::Result<()> {
    // Deleting a rule that is not there fails, and that is the state wanted, so the delete result is not checked.
    let _absent_or_removed = std::process::Command::new("netsh").args(netsh_delete_args()).status();
    let program = exe_path.to_string_lossy();
    let status = std::process::Command::new("netsh").args(netsh_firewall_args(&program, port)).status()?;
    status.success().then_some(()).ok_or_else(|| std::io::Error::other("netsh did not add the firewall rule"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn the_rule_allows_inbound_tcp_on_the_port_for_this_program_on_private_networks() {
        let args = netsh_firewall_args(r"C:\Peering\peering-host.exe", 51515);
        assert_eq!(
            args,
            strings(&[
                "advfirewall",
                "firewall",
                "add",
                "rule",
                "name=Peering Host",
                "dir=in",
                "action=allow",
                "protocol=TCP",
                "localport=51515",
                "profile=private",
                r"program=C:\Peering\peering-host.exe",
            ])
        );
    }

    #[test]
    fn a_program_path_with_spaces_is_one_argument_when_the_line_is_joined() {
        let args = netsh_firewall_args(r"C:\Program Files\Peering Host\peering-host.exe", 51515);
        let line = command_line(&args);
        assert!(line.contains(r#""name=Peering Host""#));
        assert!(line.contains(r#""program=C:\Program Files\Peering Host\peering-host.exe""#));
    }

    #[test]
    fn the_delete_removes_the_named_rule() {
        assert_eq!(netsh_delete_args().last().map(String::as_str), Some("name=Peering Host"));
    }

    #[test]
    fn quoting_follows_the_windows_argument_rules() {
        assert_eq!(command_line(&strings(&["plain", "two words"])), r#"plain "two words""#);
        assert_eq!(command_line(&strings(&["say \"hi\""])), r#""say \"hi\"""#);
        assert_eq!(command_line(&strings(&[r"C:\dir\"])), r"C:\dir\");
        assert_eq!(command_line(&strings(&[r"C:\my dir\"])), r#""C:\my dir\\""#);
        assert_eq!(command_line(&strings(&[""])), r#""""#);
    }

    #[test]
    fn a_helper_request_carries_the_port() {
        assert_eq!(helper_port(&strings(&["--firewall-rule", "51515"])), Some(51515));
        assert_eq!(helper_port(&strings(&["--other", "1"])), None);
        assert_eq!(helper_port(&strings(&["--firewall-rule", "not-a-port"])), None);
        assert_eq!(helper_port(&strings(&["--firewall-rule"])), None);
    }
}
