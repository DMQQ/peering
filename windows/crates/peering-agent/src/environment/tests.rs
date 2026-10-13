use std::collections::BTreeSet;

use super::*;

const PROFILE: &str = "C:\\Users\\me";
const APP_DATA: &str = "C:\\Users\\me\\AppData\\Roaming";

/// Windows file names are case-insensitive, so the fake is too.
struct Files(BTreeSet<String>);

impl Files {
    fn with(paths: &[&str]) -> Self {
        Self(paths.iter().map(|path| path.to_lowercase()).collect())
    }
}

impl Exists for Files {
    fn exists(&self, path: &str) -> bool {
        self.0.contains(&path.to_lowercase())
    }
}

fn search(path: &str, path_ext: Option<&str>) -> SearchEnv {
    SearchEnv::new(path, path_ext, PROFILE, Some(APP_DATA))
}

#[test]
fn the_earlier_path_entry_wins_even_when_a_later_one_has_a_better_extension() {
    let env = search("C:\\a;C:\\b", None);
    let files = Files::with(&["C:\\a\\claude.cmd", "C:\\b\\claude.exe"]);
    let found = find_binary("claude", &env, &files).expect("found");
    assert_eq!(found.path, "C:\\a\\claude.CMD");
    assert!(found.needs_cmd_wrapper);
}

#[test]
fn within_one_directory_the_pathext_order_decides() {
    let files = Files::with(&["C:\\a\\claude.cmd", "C:\\a\\claude.exe"]);
    let default_order = find_binary("claude", &search("C:\\a", None), &files).expect("found");
    assert_eq!(default_order.path, "C:\\a\\claude.EXE");

    let cmd_first = find_binary("claude", &search("C:\\a", Some(".CMD;.EXE")), &files).expect("found");
    assert_eq!(cmd_first.path, "C:\\a\\claude.CMD");
}

#[test]
fn an_unset_pathext_falls_back_to_the_windows_default_list() {
    let files = Files::with(&["C:\\a\\tool.com"]);
    let found = find_binary("tool", &search("C:\\a", None), &files).expect("found");
    assert_eq!(found.path, "C:\\a\\tool.COM");
    assert!(!found.needs_cmd_wrapper);
}

#[test]
fn a_cmd_or_bat_shim_needs_the_cmd_wrapper_and_an_executable_does_not() {
    let shim = find_binary("gemini", &search("C:\\a", None), &Files::with(&["C:\\a\\gemini.bat"])).expect("found");
    assert!(shim.needs_cmd_wrapper);

    let executable = find_binary("codex", &search("C:\\a", None), &Files::with(&["C:\\a\\codex.exe"])).expect("found");
    assert!(!executable.needs_cmd_wrapper);
}

#[test]
fn a_quoted_path_entry_is_searched_without_its_quotes() {
    let env = search("\"C:\\Program Files\\Tools\"", None);
    let files = Files::with(&["C:\\Program Files\\Tools\\aider.EXE"]);
    assert_eq!(find_binary("aider", &env, &files).expect("found").path, "C:\\Program Files\\Tools\\aider.EXE");
}

#[test]
fn the_per_user_install_folders_are_searched_after_the_path() {
    let files = Files::with(&["C:\\Users\\me\\.local\\bin\\claude.exe"]);
    let found = find_binary("claude", &search("C:\\a", None), &files).expect("found");
    assert_eq!(found.path, "C:\\Users\\me\\.local\\bin\\claude.EXE");

    let npm = Files::with(&["C:\\Users\\me\\AppData\\Roaming\\npm\\codex.cmd"]);
    let found = find_binary("codex", &search("", None), &npm).expect("found");
    assert_eq!(found.path, "C:\\Users\\me\\AppData\\Roaming\\npm\\codex.CMD");
    assert!(found.needs_cmd_wrapper);
}

#[test]
fn the_claude_local_folder_is_searched_last() {
    let files = Files::with(&["C:\\Users\\me\\.claude\\local\\claude.exe", "C:\\Users\\me\\.local\\bin\\claude.exe"]);
    let found = find_binary("claude", &search("", None), &files).expect("found");
    assert_eq!(found.path, "C:\\Users\\me\\.local\\bin\\claude.EXE");
}

#[test]
fn a_name_with_characters_outside_the_allowed_set_is_rejected() {
    let files = Files::with(&["C:\\a\\claude.exe", "C:\\a\\..\\claude.exe"]);
    let env = search("C:\\a", None);
    assert_eq!(find_binary("", &env, &files), None);
    assert_eq!(find_binary("claude.exe", &env, &files), None);
    assert_eq!(find_binary("..\\claude", &env, &files), None);
    assert_eq!(find_binary("claude code", &env, &files), None);
    assert!(is_valid_binary_name("claude-code_2"));
}

#[test]
fn a_binary_that_is_not_on_disk_is_not_found() {
    let env = search("C:\\a;C:\\b", Some(".EXE"));
    assert_eq!(find_binary("opencode", &env, &Files::with(&["C:\\a\\claude.exe"])), None);
}

#[test]
fn a_file_without_a_pathext_extension_is_not_a_binary() {
    let files = Files::with(&["C:\\a\\claude"]);
    assert_eq!(find_binary("claude", &search("C:\\a", None), &files), None);
}

#[test]
fn a_cmd_shim_is_launched_through_cmd_with_its_arguments_after_the_path() {
    let shim = Resolved {
        path: "C:\\npm\\codex.cmd".to_owned(),
        needs_cmd_wrapper: true,
    };
    let (program, args) = launch_command(&shim, &["--model".to_owned(), "o3".to_owned()]);
    assert_eq!(program, "cmd.exe");
    assert_eq!(args, ["/c", "C:\\npm\\codex.cmd", "--model", "o3"]);
}

#[test]
fn an_executable_is_launched_directly() {
    let exe = Resolved {
        path: "C:\\bin\\claude.exe".to_owned(),
        needs_cmd_wrapper: false,
    };
    let (program, args) = launch_command(&exe, &["--resume".to_owned()]);
    assert_eq!(program, "C:\\bin\\claude.exe");
    assert_eq!(args, ["--resume"]);
}
