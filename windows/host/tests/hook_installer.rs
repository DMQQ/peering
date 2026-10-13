
//! The installer against a real folder.

use std::fs;

use peering_host::hooks::installer::{script_text, HookFiles, InstallError};

fn files() -> (tempdir::Dir, HookFiles) {
    let dir = tempdir::Dir::new();
    let hook_files = HookFiles::new(&dir.0.join("home"), &dir.0.join("support dir"));
    (dir, hook_files)
}

mod tempdir {
    use std::path::PathBuf;

    pub struct Dir(pub PathBuf);

    impl Dir {
        pub fn new() -> Self {
            let path = std::env::temp_dir().join(format!("peering-hooks-{}-{:?}", std::process::id(), std::thread::current().id()));
            std::fs::create_dir_all(&path).expect("creates the folder");
            Self(path)
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            drop(std::fs::remove_dir_all(&self.0));
        }
    }
}

#[test]
fn installing_creates_the_settings_and_the_script_and_uninstalling_removes_both() {
    let (_dir, files) = files();
    files.install(4000, "tok").expect("installs");
    assert!(files.is_installed());
    assert!(fs::read_to_string(&files.script).expect("script").contains("127.0.0.1:4000/hook"));
    files.uninstall().expect("uninstalls");
    assert!(!files.is_installed());
    assert!(!files.script.exists());
}

#[test]
fn the_users_own_settings_survive_and_a_backup_is_kept_once() {
    let (_dir, files) = files();
    fs::create_dir_all(files.settings.parent().expect("parent")).expect("folder");
    fs::write(&files.settings, r#"{"model":"opus"}"#).expect("seed");
    files.install(1, "a").expect("installs");
    files.install(2, "b").expect("installs again");
    let text = fs::read_to_string(&files.settings).expect("settings");
    assert!(text.contains("\"model\": \"opus\""));
    assert_eq!(text.matches("peering-hook.cmd").count(), 2);
    let backup = files.settings.with_extension("json.peering-backup");
    assert_eq!(fs::read_to_string(backup).expect("backup"), r#"{"model":"opus"}"#);
    assert!(fs::read_to_string(&files.script).expect("script").contains("127.0.0.1:2/hook"));
}

#[test]
fn a_settings_file_that_is_not_json_is_left_alone() {
    let (_dir, files) = files();
    fs::create_dir_all(files.settings.parent().expect("parent")).expect("folder");
    fs::write(&files.settings, "{ not json").expect("seed");
    assert!(matches!(files.install(1, "a"), Err(InstallError::UnreadableSettings)));
    assert_eq!(fs::read_to_string(&files.settings).expect("settings"), "{ not json");
    assert!(!files.script.exists());
}

#[test]
fn the_command_is_quoted_with_forward_slashes() {
    let (_dir, files) = files();
    let command = files.command();
    assert!(command.starts_with('"') && command.ends_with("peering-hook.cmd\""));
    assert!(!command.contains('\\'));
}

#[test]
fn the_script_carries_the_token_and_exits_clean() {
    let text = script_text(5, "tok");
    assert!(text.contains("x-peering-token: tok"));
    assert!(text.ends_with("exit /b 0\r\n"));
}

#[test]
fn a_failed_write_leaves_the_previous_settings_untouched() {
    let (_dir, files) = files();
    fs::create_dir_all(files.settings.parent().expect("parent")).expect("folder");
    fs::write(&files.settings, r#"{"model":"opus"}"#).expect("seed");
    fs::create_dir(files.settings.with_extension("json.peering-tmp")).expect("a folder where the temporary file goes");
    assert!(files.install(1, "a").is_err());
    assert_eq!(fs::read_to_string(&files.settings).expect("settings"), r#"{"model":"opus"}"#);
}

#[test]
fn a_successful_write_leaves_no_temporary_file_behind() {
    let (_dir, files) = files();
    files.install(1, "a").expect("installs");
    assert!(!files.settings.with_extension("json.peering-tmp").exists());
}
