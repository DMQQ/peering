//! Named secrets as files, each sealed by a `Protector`. Windows seals with DPAPI (`dpapi/sys.rs`); the file rules here
//! are the same on every platform and run under test with a stand-in protector.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use peering_core::ports::secret_store::SecretStore;

#[cfg(windows)]
mod sys;

#[cfg(windows)]
pub use sys::DpapiProtector;

const DIRECTORY_NAME: &str = "Peering Host";

/// Seals and opens secret bytes. `None` means the operation failed and nothing was written or returned.
pub trait Protector {
    fn protect(&self, plain: &[u8]) -> Option<Vec<u8>>;
    fn unprotect(&self, sealed: &[u8]) -> Option<Vec<u8>>;
}

/// One sealed file per secret name inside `directory`. A write goes to a temporary file that is renamed over the
/// target, so a failed write leaves the previous value in place.
pub struct SecretFiles<P: Protector> {
    directory: PathBuf,
    protector: P,
}

#[cfg(windows)]
pub type DpapiStore = SecretFiles<DpapiProtector>;

impl<P: Protector> SecretFiles<P> {
    pub fn new(directory: PathBuf, protector: P) -> Self {
        Self { directory, protector }
    }
}

/// `%LOCALAPPDATA%\Peering Host`, or None when the variable is unset.
pub fn default_directory() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA").map(|base| PathBuf::from(base).join(DIRECTORY_NAME))
}

/// The file for `name` inside `directory`. Names are limited to ASCII letters, digits, `-` and `_`, so no name can
/// reach a separator, a parent directory or a drive.
pub fn secret_path(directory: &Path, name: &str) -> Option<PathBuf> {
    let well_formed = !name.is_empty()
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_');
    well_formed.then(|| directory.join(name))
}

impl<P: Protector> SecretStore for SecretFiles<P> {
    fn read(&self, name: &str) -> Option<Vec<u8>> {
        let path = secret_path(&self.directory, name)?;
        let sealed = fs::read(path).ok()?;
        self.protector.unprotect(&sealed)
    }

    fn write(&self, name: &str, value: &[u8]) -> bool {
        let Some(path) = secret_path(&self.directory, name) else {
            return false;
        };
        let Some(sealed) = self.protector.protect(value) else {
            return false;
        };
        fs::create_dir_all(&self.directory).is_ok() && write_atomically(&path, &sealed).is_ok()
    }

    fn remove(&self, name: &str) -> bool {
        let Some(path) = secret_path(&self.directory, name) else {
            return true;
        };
        match fs::remove_file(path) {
            Ok(()) => true,
            Err(error) => error.kind() == io::ErrorKind::NotFound,
        }
    }
}

fn write_atomically(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temporary = path.with_extension("tmp");
    let result = write_and_rename(&temporary, path, bytes);
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn write_and_rename(temporary: &Path, target: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = File::create(temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    fs::rename(temporary, target)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reverses the bytes and tags them, so a sealed value is visibly different from the plain one.
    struct ReversingProtector {
        refuse_protect: bool,
    }

    impl Protector for ReversingProtector {
        fn protect(&self, plain: &[u8]) -> Option<Vec<u8>> {
            if self.refuse_protect {
                return None;
            }
            let mut sealed: Vec<u8> = plain.iter().rev().copied().collect();
            sealed.push(0xAA);
            Some(sealed)
        }

        fn unprotect(&self, sealed: &[u8]) -> Option<Vec<u8>> {
            let (last, body) = sealed.split_last()?;
            (*last == 0xAA).then(|| body.iter().rev().copied().collect())
        }
    }

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new(test: &str) -> Self {
            let path = std::env::temp_dir().join(format!("peering-dpapi-{test}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            Self(path)
        }

        fn store(&self, refuse_protect: bool) -> SecretFiles<ReversingProtector> {
            SecretFiles::new(self.0.clone(), ReversingProtector { refuse_protect })
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_secret_round_trips_through_the_protector() {
        let dir = TestDirectory::new("round-trip");
        let store = dir.store(false);
        assert!(store.write("host-key", b"secret bytes"));
        assert_eq!(store.read("host-key"), Some(b"secret bytes".to_vec()));
    }

    #[test]
    fn the_file_holds_the_sealed_bytes_not_the_plain_value() {
        let dir = TestDirectory::new("sealed-on-disk");
        assert!(dir.store(false).write("pin", b"1234"));
        let on_disk = fs::read(dir.0.join("pin")).expect("the secret file exists");
        assert_eq!(on_disk, vec![b'4', b'3', b'2', b'1', 0xAA]);
    }

    #[test]
    fn a_refused_seal_keeps_the_previous_value() {
        let dir = TestDirectory::new("refused-seal");
        assert!(dir.store(false).write("host-key", b"old"));
        assert!(!dir.store(true).write("host-key", b"new"));
        assert_eq!(dir.store(false).read("host-key"), Some(b"old".to_vec()));
    }

    #[test]
    fn a_failed_temporary_write_keeps_the_previous_value() {
        let dir = TestDirectory::new("failed-temporary");
        assert!(dir.store(false).write("host-key", b"old"));
        fs::create_dir(dir.0.join("host-key.tmp")).expect("a directory at the temporary name blocks the write");
        assert!(!dir.store(false).write("host-key", b"new"));
        assert_eq!(dir.store(false).read("host-key"), Some(b"old".to_vec()));
    }

    #[test]
    fn an_unknown_name_reads_as_none() {
        let dir = TestDirectory::new("unknown");
        assert_eq!(dir.store(false).read("missing"), None);
    }

    #[test]
    fn remove_clears_the_value_and_is_true_when_nothing_was_there() {
        let dir = TestDirectory::new("remove");
        let store = dir.store(false);
        assert!(store.write("pin", b"1"));
        assert!(store.remove("pin"));
        assert_eq!(store.read("pin"), None);
        assert!(store.remove("pin"));
    }

    #[test]
    fn a_name_that_cannot_be_a_file_is_refused_on_write_and_reads_empty() {
        let dir = TestDirectory::new("bad-name");
        let store = dir.store(false);
        assert!(!store.write("../escape", b"x"));
        assert_eq!(store.read("../escape"), None);
    }

    #[test]
    fn secret_path_rejects_separators_dots_and_empty_names() {
        let base = Path::new("base");
        assert_eq!(secret_path(base, "host-key_1"), Some(base.join("host-key_1")));
        assert_eq!(secret_path(base, ""), None);
        assert_eq!(secret_path(base, "a/b"), None);
        assert_eq!(secret_path(base, r"a\b"), None);
        assert_eq!(secret_path(base, "a.b"), None);
        assert_eq!(secret_path(base, ".."), None);
        assert_eq!(secret_path(base, "C:x"), None);
    }
}
