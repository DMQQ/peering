use std::collections::{BTreeMap, BTreeSet};

use super::*;

const PROFILE: &str = "C:\\Users\\me";
const APP_DATA: &str = "C:\\Users\\me\\AppData\\Roaming";

/// Windows file names are case-insensitive, so the fake is too.
struct Files(BTreeSet<String>, BTreeMap<String, String>);

impl Files {
    fn with(paths: &[&str]) -> Self {
        Self(paths.iter().map(|path| path.to_lowercase()).collect(), BTreeMap::new())
    }

    fn holding(mut self, path: &str, text: &str) -> Self {
        self.0.insert(path.to_lowercase());
        self.1.insert(path.to_lowercase(), text.to_owned());
        self
    }
}

impl Exists for Files {
    fn exists(&self, path: &str) -> bool {
        self.0.contains(&path.to_lowercase())
    }

    fn read_text(&self, path: &str) -> Option<String> {
        self.1.get(&path.to_lowercase()).cloned()
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

const NPM_SHIM: &str = "@ECHO off\r\nIF EXIST \"%dp0%\\node.exe\" (\r\n  SET \"_prog=%dp0%\\node.exe\"\r\n) ELSE (\r\n  SET \"_prog=node\"\r\n)\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & \"%_prog%\"  \"%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js\" %*\r\n";
const SCRIPT: &str = "C:\\npm\\node_modules\\@openai\\codex\\bin\\codex.js";

fn shim() -> Resolved {
    Resolved { path: "C:\\npm\\codex.cmd".to_owned(), needs_cmd_wrapper: true }
}

fn words(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn an_npm_shim_is_replaced_by_node_running_its_script() {
    let files = Files::with(&[SCRIPT, "C:\\node\\node.exe"]).holding("C:\\npm\\codex.cmd", NPM_SHIM);
    let launched = launch_command(&shim(), &words(&["a & calc", "%PATH%"]), &search("C:\\node", None), &files);
    assert_eq!(
        launched,
        Ok(("C:\\node\\node.EXE".to_owned(), words(&[SCRIPT, "a & calc", "%PATH%"])))
    );
}

#[test]
fn the_node_beside_the_shim_is_preferred() {
    let files = Files::with(&[SCRIPT, "C:\\npm\\node.exe", "C:\\node\\node.exe"]).holding("C:\\npm\\codex.cmd", NPM_SHIM);
    let (program, _) = launch_command(&shim(), &[], &search("C:\\node", None), &files).expect("launches");
    assert_eq!(program, "C:\\npm\\node.exe");
}

#[test]
fn the_shim_script_is_read_from_the_quoted_path_after_the_program() {
    assert_eq!(npm_shim_script(NPM_SHIM, "C:\\npm"), Some(SCRIPT.to_owned()));
    assert_eq!(npm_shim_script("@\"%~dp0\\real.exe\" %*", "C:\\npm"), None);
    assert_eq!(npm_shim_script("\"%_prog%\" \"%dp0%\\%X%\" %*", "C:\\npm"), None);
}

#[test]
fn an_unreadable_shim_goes_through_cmd_with_its_arguments_after_the_path() {
    let launched = launch_command(&shim(), &words(&["--model", "o3"]), &search("C:\\a", None), &Files::with(&[]));
    assert_eq!(launched, Ok(("cmd.exe".to_owned(), words(&["/c", "C:\\npm\\codex.cmd", "--model", "o3"]))));
}

#[test]
fn cmd_is_refused_any_argument_it_would_parse() {
    for argument in ["\" & calc & \"", "%USERPROFILE%", "a\nb", "x|y", "(a)", "^", "!v!"] {
        let launched = launch_command(&shim(), &words(&["-m", argument]), &search("C:\\a", None), &Files::with(&[]));
        assert_eq!(launched, Err(UnsafeArgument), "{argument:?}");
    }
}

#[test]
fn an_executable_is_launched_directly() {
    let exe = Resolved { path: "C:\\bin\\claude.exe".to_owned(), needs_cmd_wrapper: false };
    let launched = launch_command(&exe, &words(&["--resume", "a & b"]), &search("C:\\a", None), &Files::with(&[]));
    assert_eq!(launched, Ok(("C:\\bin\\claude.exe".to_owned(), words(&["--resume", "a & b"]))));
}
