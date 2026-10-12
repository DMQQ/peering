use super::*;

const ALL: &[&str] = &[
    "C:\\Tools\\pwsh.exe",
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    "C:\\Windows\\System32\\cmd.exe",
];

fn search() -> ShellSearch {
    ShellSearch {
        path_entries: vec!["C:\\Tools\\".to_owned(), "C:\\Other".to_owned()],
        program_files: Some("C:\\Program Files".to_owned()),
        system_root: Some("C:\\Windows".to_owned()),
        command_interpreter: None,
    }
}

fn found(installed: &'static [&'static str]) -> impl Fn(&str) -> bool {
    move |path| installed.contains(&path)
}

#[test]
fn powershell_7_comes_first_then_windows_powershell_then_cmd() {
    let shells = discover(&search(), &found(ALL));
    let programs: Vec<&str> = shells.iter().map(|shell| shell.program.as_str()).collect();
    assert_eq!(programs, ALL);
    assert_eq!(shells[2].kind, ShellKind::Cmd);
    assert!(shells[2].arguments.is_empty());
}

#[test]
fn powershell_7_is_found_in_program_files_when_it_is_not_on_the_path() {
    let shells = discover(&search(), &found(&["C:\\Program Files\\PowerShell\\7\\pwsh.exe"]));
    assert_eq!(shells[0].program, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
}

#[test]
fn a_pc_without_powershell_7_starts_windows_powershell() {
    let shells = discover(&search(), &found(&ALL[1..]));
    assert_eq!(shells[0].kind, ShellKind::PowerShell);
    assert!(shells[0].program.ends_with("powershell.exe"));
}

#[test]
fn powershell_runs_the_finish_hook_after_the_profile() {
    let shells = discover(&search(), &found(ALL));
    assert_eq!(shells[0].arguments[..3], ["-NoLogo", "-NoExit", "-Command"]);
    assert_eq!(shells[0].arguments[3], POWERSHELL_FINISH_HOOK);
}

#[test]
fn comspec_is_preferred_for_cmd() {
    let mut search = search();
    search.command_interpreter = Some("D:\\cmd.exe".to_owned());
    let shells = discover(&search, &found(&["D:\\cmd.exe", "C:\\Windows\\System32\\cmd.exe"]));
    assert_eq!(shells[0].program, "D:\\cmd.exe");
}

#[test]
fn nothing_found_is_an_empty_list() {
    assert!(discover(&search(), &found(&[])).is_empty());
}

#[test]
fn the_environment_forces_term_whatever_case_the_user_has_it_in() {
    let user = [("Path".to_owned(), "C:\\x".to_owned()), ("term".to_owned(), "dumb".to_owned())];
    let environment = terminal_environment(user);
    assert!(environment.contains(&("Path".to_owned(), "C:\\x".to_owned())));
    assert!(environment.contains(&("TERM".to_owned(), "xterm-256color".to_owned())));
    assert!(!environment.iter().any(|(name, _)| name == "term"));
    assert!(environment.contains(&("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN".to_owned(), "1".to_owned())));
}
