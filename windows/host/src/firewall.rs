//! The inbound rule that lets phones reach the host on the local network. Changing the firewall needs elevation, so the
//! host starts a copy of itself with `--firewall-rule <port>` through ShellExecuteW "runas"; that copy applies the rule.
//! The builders are pure and tested natively. The Windows parts are unverified until run on Windows.

use peering_core::settings::DEFAULT_PORT;


pub const RULE_NAME: &str = "Peering Host";
pub const MDNS_RULE_NAME: &str = "Peering Host mDNS";
const MDNS_PORT: u16 = 5353;
pub const HELPER_FLAG: &str = "--firewall-rule";

/// The netsh arguments for an inbound TCP rule on `port` for the executable at `exe_path`, on private networks only and
/// only from the local subnet, so a router that forwards the port does not expose it.
pub fn netsh_firewall_args(exe_path: &str, port: u16) -> Vec<String> {
    netsh_rule_args(RULE_NAME, "TCP", port, exe_path)
}

/// The rule for mDNS: without inbound UDP 5353 Windows drops the multicast queries that make the host findable by name.
pub fn netsh_mdns_args(exe_path: &str) -> Vec<String> {
    netsh_rule_args(MDNS_RULE_NAME, "UDP", MDNS_PORT, exe_path)
}

fn netsh_rule_args(name: &str, protocol: &str, port: u16, exe_path: &str) -> Vec<String> {
    vec![
        "advfirewall".to_owned(),
        "firewall".to_owned(),
        "add".to_owned(),
        "rule".to_owned(),
        format!("name={name}"),
        "dir=in".to_owned(),
        "action=allow".to_owned(),
        format!("protocol={protocol}"),
        format!("localport={port}"),
        "profile=private".to_owned(),
        "remoteip=localsubnet".to_owned(),
        format!("program={exe_path}"),
    ]
}

/// The arguments that remove this program's rule called `name` before it is added again, so a changed port never leaves
/// a stale rule. The program is named so another application's rule of the same name is not removed with it.
pub fn netsh_delete_args(name: &str, exe_path: &str) -> Vec<String> {
    vec![
        "advfirewall".to_owned(),
        "firewall".to_owned(),
        "delete".to_owned(),
        "rule".to_owned(),
        format!("name={name}"),
        format!("program={exe_path}"),
    ]
}

/// The port named by a `--firewall-rule <port>` request, if the arguments are one. The elevated copy trusts nothing it is
/// handed, so only the host's own port is accepted: 0 and every other value are refused.
pub fn helper_port(arguments: &[String]) -> Option<u16> {
    let position = arguments.iter().position(|argument| argument == HELPER_FLAG)?;
    let port: u16 = arguments.get(position + 1)?.parse().ok()?;
    (port == DEFAULT_PORT).then_some(port)
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

/// How the elevated copy that applies the rule ended, as far as the window can tell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HelperResult {
    /// The helper exited 0: the rules were added and found again.
    Applied,
    /// The helper ran and exited with this code.
    Failed(u32),
    /// The Windows prompt was declined.
    Declined,
    TimedOut,
    CouldNotStart(String),
}

impl HelperResult {
    /// The sentence for the window when the rule is not in place, or `None` when it is.
    pub fn failure_reason(&self) -> Option<String> {
        match self {
            Self::Applied => None,
            Self::Failed(code) => Some(format!("the helper that adds the rule failed (exit code {code})")),
            Self::Declined => Some("the Windows prompt was declined".to_owned()),
            Self::TimedOut => Some("the helper did not finish in time".to_owned()),
            Self::CouldNotStart(reason) => Some(format!("the helper could not start: {reason}")),
        }
    }
}

/// One netsh call in the plan that replaces the rules.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuleStep {
    /// A failure is fine: the rule it removes may not be there.
    Remove(Vec<String>),
    /// A failure stops the plan before anything that was working is touched.
    Add(Vec<String>),
    Verify(Vec<String>),
    Rename(Vec<String>),
}

impl RuleStep {
    fn arguments(&self) -> &[String] {
        match self {
            Self::Remove(arguments) | Self::Add(arguments) | Self::Verify(arguments) | Self::Rename(arguments) => arguments,
        }
    }

    fn what(&self) -> &'static str {
        match self {
            Self::Remove(_) => "remove a rule",
            Self::Add(_) => "add a rule",
            Self::Verify(_) => "find the new rule again",
            Self::Rename(_) => "rename the new rule",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("netsh could not {what}: {reason}")]
pub struct RuleError {
    pub what: &'static str,
    pub reason: String,
}

fn temporary_name(name: &str) -> String {
    format!("{name} (new)")
}

fn netsh_show_args(name: &str) -> Vec<String> {
    ["advfirewall", "firewall", "show", "rule"].iter().map(ToString::to_string).chain([format!("name={name}")]).collect()
}

fn netsh_rename_args(from: &str, to: &str) -> Vec<String> {
    ["advfirewall", "firewall", "set", "rule"]
        .iter()
        .map(ToString::to_string)
        .chain([format!("name={from}"), "new".to_owned(), format!("name={to}")])
        .collect()
}

/// The steps that put the two rules in place without a moment when neither exists: any rule left by an earlier failed run
/// is cleared, the new rules are added under temporary names and found again, and only then are the old rules removed and
/// the new ones given the real names. A failure before the old rules are removed leaves them working.
pub fn rule_plan(exe_path: &str, port: u16) -> Vec<RuleStep> {
    let rules = [(RULE_NAME, netsh_firewall_args(exe_path, port)), (MDNS_RULE_NAME, netsh_mdns_args(exe_path))];
    let mut plan = Vec::new();
    for (name, _) in &rules {
        plan.push(RuleStep::Remove(netsh_delete_args(&temporary_name(name), exe_path)));
    }
    for (name, arguments) in &rules {
        let mut renamed = arguments.clone();
        if let Some(position) = renamed.iter().position(|argument| argument.starts_with("name=")) {
            renamed[position] = format!("name={}", temporary_name(name));
        }
        plan.push(RuleStep::Add(renamed));
    }
    for (name, _) in &rules {
        plan.push(RuleStep::Verify(netsh_show_args(&temporary_name(name))));
    }
    for (name, _) in &rules {
        plan.push(RuleStep::Remove(netsh_delete_args(name, exe_path)));
        plan.push(RuleStep::Rename(netsh_rename_args(&temporary_name(name), name)));
    }
    for (name, _) in &rules {
        plan.push(RuleStep::Verify(netsh_show_args(name)));
    }
    plan
}

/// Runs the plan through `run`, which returns whether a netsh call with those arguments succeeded and why not if it did not.
pub fn run_plan(
    plan: &[RuleStep],
    mut run: impl FnMut(&[String]) -> Result<(), String>,
) -> Result<(), RuleError> {
    for step in plan {
        match (run(step.arguments()), step) {
            (Ok(()), _) | (Err(_), RuleStep::Remove(_)) => {}
            (Err(reason), step) => return Err(RuleError { what: step.what(), reason }),
        }
    }
    Ok(())
}

#[cfg(windows)]
const NETSH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);
/// The Windows prompt waits for a person, and then up to ten netsh calls run.
#[cfg(windows)]
const HELPER_WAIT_MILLISECONDS: u32 = 180_000;

/// Starts the elevated copy that applies the rules and waits for it, so the result is the helper's own and not just that
/// it started. Blocks until the person answers the prompt, so it runs on a worker thread.
#[cfg(windows)]
pub fn request_rule_elevated(exe_path: &std::path::Path, port: u16) -> HelperResult {
    use windows::core::{HRESULT, HSTRING, PCWSTR};
    use windows::Win32::Foundation::{CloseHandle, ERROR_CANCELLED};
    use windows::Win32::UI::Shell::{ShellExecuteExW, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW};
    use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;

    let verb = HSTRING::from("runas");
    let file = HSTRING::from(exe_path.to_string_lossy().as_ref());
    let parameters = HSTRING::from(command_line(&[HELPER_FLAG.to_owned(), port.to_string()]));
    let mut info = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS,
        lpVerb: PCWSTR(verb.as_ptr()),
        lpFile: PCWSTR(file.as_ptr()),
        lpParameters: PCWSTR(parameters.as_ptr()),
        nShow: SW_HIDE.0,
        ..Default::default()
    };
    // SAFETY: `info` is fully initialised, its size is set, and the three strings it points at outlive the call.
    if let Err(error) = unsafe { ShellExecuteExW(&mut info) } {
        return if error.code() == HRESULT::from_win32(ERROR_CANCELLED.0) {
            HelperResult::Declined
        } else {
            HelperResult::CouldNotStart(error.message())
        };
    }
    let process = info.hProcess;
    if process.is_invalid() {
        return HelperResult::CouldNotStart("Windows did not return the helper process".to_owned());
    }
    let result = helper_exit(process);
    // SAFETY: `process` is the handle ShellExecuteExW returned because SEE_MASK_NOCLOSEPROCESS was set, and nothing uses it
    // after this. A handle that cannot be closed is leaked, which costs nothing while the window runs.
    let _closed = unsafe { CloseHandle(process) };
    result
}

/// Waits for the helper process to end and reads its exit code.
#[cfg(windows)]
fn helper_exit(process: windows::Win32::Foundation::HANDLE) -> HelperResult {
    use windows::Win32::Foundation::WAIT_OBJECT_0;
    use windows::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject};

    // SAFETY: `process` is a live process handle owned by the caller for the duration of both calls, and `code` is a live local.
    unsafe {
        if WaitForSingleObject(process, HELPER_WAIT_MILLISECONDS) != WAIT_OBJECT_0 {
            return HelperResult::TimedOut;
        }
        let mut code = 0u32;
        match GetExitCodeProcess(process, &mut code) {
            Ok(()) if code == 0 => HelperResult::Applied,
            Ok(()) => HelperResult::Failed(code),
            Err(error) => HelperResult::CouldNotStart(error.message()),
        }
    }
}

/// Replaces the host's inbound rules following `rule_plan`. Runs in the elevated copy started by `request_rule_elevated`.
#[cfg(windows)]
pub fn apply_rule(exe_path: &std::path::Path, port: u16) -> std::io::Result<()> {
    let program = exe_path.to_string_lossy();
    let netsh = crate::tools::system_tool("netsh");
    run_plan(&rule_plan(&program, port), |arguments| {
        let outcome = crate::tools::run(&netsh, arguments, NETSH_TIMEOUT);
        if outcome.succeeded() { Ok(()) } else { Err(outcome.describe()) }
    })
    .map_err(|error| std::io::Error::other(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn the_rule_allows_inbound_tcp_on_the_port_for_this_program_from_the_local_subnet_on_private_networks() {
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
                "remoteip=localsubnet",
                r"program=C:\Peering\peering-host.exe",
            ])
        );
    }

    #[test]
    fn mdns_gets_its_own_udp_rule_from_the_local_subnet() {
        let args = netsh_mdns_args(r"C:\Peering\peering-host.exe");
        for expected in ["name=Peering Host mDNS", "protocol=UDP", "localport=5353", "dir=in", "profile=private", "remoteip=localsubnet"] {
            assert!(args.contains(&expected.to_owned()), "{expected}");
        }
    }

    #[test]
    fn the_two_rules_have_different_names_so_one_delete_cannot_remove_both() {
        assert_ne!(RULE_NAME, MDNS_RULE_NAME);
        assert!(netsh_delete_args(MDNS_RULE_NAME, "p").contains(&"name=Peering Host mDNS".to_owned()));
    }

    #[test]
    fn a_program_path_with_spaces_is_one_argument_when_the_line_is_joined() {
        let args = netsh_firewall_args(r"C:\Program Files\Peering Host\peering-host.exe", 51515);
        let line = command_line(&args);
        assert!(line.contains(r#""name=Peering Host""#));
        assert!(line.contains(r#""program=C:\Program Files\Peering Host\peering-host.exe""#));
    }

    #[test]
    fn the_delete_removes_only_the_rule_of_this_program() {
        let args = netsh_delete_args(RULE_NAME, r"C:\Peering\peering-host.exe");
        assert!(args.contains(&"name=Peering Host".to_owned()));
        assert_eq!(args.last().map(String::as_str), Some(r"program=C:\Peering\peering-host.exe"));
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
        assert_eq!(helper_port(&strings(&["--firewall-rule", "0"])), None);
        assert_eq!(helper_port(&strings(&["--firewall-rule", "22"])), None);
        assert_eq!(helper_port(&strings(&["--firewall-rule"])), None);
    }

    fn plan_names(plan: &[RuleStep]) -> Vec<&'static str> {
        plan.iter().map(RuleStep::what).collect()
    }

    fn joined(step: &RuleStep) -> String {
        step.arguments().join(" ")
    }

    #[test]
    fn the_new_rules_are_added_and_found_before_any_old_rule_is_removed() {
        let plan = rule_plan(r"C:\Peering\peering-host.exe", 51515);
        let first_old_removal = plan
            .iter()
            .position(|step| matches!(step, RuleStep::Remove(arguments) if arguments.contains(&"name=Peering Host".to_owned())))
            .expect("the old rule is removed");
        let adds = plan.iter().filter(|step| matches!(step, RuleStep::Add(_))).count();
        let verifies_before = plan[..first_old_removal].iter().filter(|step| matches!(step, RuleStep::Verify(_))).count();
        assert_eq!(adds, 2);
        assert_eq!(verifies_before, 2);
        assert!(plan[..first_old_removal].iter().filter(|step| matches!(step, RuleStep::Add(_))).count() == 2);
    }

    #[test]
    fn the_added_rules_carry_a_temporary_name_so_removing_the_old_ones_cannot_take_them() {
        let plan = rule_plan(r"C:\Peering\peering-host.exe", 51515);
        let added: Vec<String> = plan.iter().filter(|step| matches!(step, RuleStep::Add(_))).map(joined).collect();
        assert!(added[0].contains("name=Peering Host (new)"));
        assert!(added[1].contains("name=Peering Host mDNS (new)"));
        assert!(added[0].contains("localport=51515") && added[0].contains("remoteip=localsubnet"));
    }

    #[test]
    fn the_plan_ends_by_finding_both_rules_under_their_real_names() {
        let plan = rule_plan(r"C:\Peering\peering-host.exe", 51515);
        let last_two: Vec<String> = plan[plan.len() - 2..].iter().map(joined).collect();
        assert!(last_two[0].ends_with("show rule name=Peering Host"));
        assert!(last_two[1].ends_with("show rule name=Peering Host mDNS"));
        assert_eq!(plan_names(&plan[plan.len() - 2..]), ["find the new rule again", "find the new rule again"]);
    }

    #[test]
    fn a_failed_add_stops_the_plan_before_the_old_rules_are_touched() {
        let plan = rule_plan(r"C:\Peering\peering-host.exe", 51515);
        let mut calls = Vec::new();
        let result = run_plan(&plan, |arguments| {
            calls.push(arguments.join(" "));
            if arguments.contains(&"add".to_owned()) { Err("it exited with code 1".to_owned()) } else { Ok(()) }
        });
        assert_eq!(result, Err(RuleError { what: "add a rule", reason: "it exited with code 1".to_owned() }));
        assert!(calls.iter().all(|call| !call.contains("delete rule name=Peering Host program=")), "{calls:?}");
    }

    #[test]
    fn a_new_rule_that_cannot_be_found_stops_the_plan_before_the_old_rules_are_touched() {
        let plan = rule_plan(r"C:\Peering\peering-host.exe", 51515);
        let mut removed_old = false;
        let result = run_plan(&plan, |arguments| {
            if arguments.contains(&"delete".to_owned()) && arguments.contains(&"name=Peering Host".to_owned()) {
                removed_old = true;
            }
            if arguments.contains(&"show".to_owned()) { Err("it exited with code 1".to_owned()) } else { Ok(()) }
        });
        assert_eq!(result.map_err(|error| error.what), Err("find the new rule again"));
        assert!(!removed_old);
    }

    #[test]
    fn removing_a_rule_that_is_not_there_does_not_fail_the_plan() {
        let plan = rule_plan(r"C:\Peering\peering-host.exe", 51515);
        let result = run_plan(&plan, |arguments| {
            if arguments.contains(&"delete".to_owned()) { Err("it exited with code 1".to_owned()) } else { Ok(()) }
        });
        assert_eq!(result, Ok(()));
    }

    #[test]
    fn a_rename_that_fails_is_reported() {
        let plan = rule_plan(r"C:\Peering\peering-host.exe", 51515);
        let result = run_plan(&plan, |arguments| {
            if arguments.contains(&"set".to_owned()) { Err("it did not finish in time".to_owned()) } else { Ok(()) }
        });
        assert_eq!(result.map_err(|error| error.what), Err("rename the new rule"));
    }

    #[test]
    fn the_helper_result_says_what_went_wrong_or_nothing_when_the_rule_is_in_place() {
        assert_eq!(HelperResult::Applied.failure_reason(), None);
        assert!(HelperResult::Failed(1).failure_reason().is_some_and(|text| text.contains("exit code 1")));
        assert!(HelperResult::Declined.failure_reason().is_some_and(|text| text.contains("declined")));
        assert!(HelperResult::TimedOut.failure_reason().is_some());
        assert!(HelperResult::CouldNotStart("no".to_owned()).failure_reason().is_some_and(|text| text.contains("no")));
    }
}
