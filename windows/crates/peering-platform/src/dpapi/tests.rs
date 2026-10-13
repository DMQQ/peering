use std::sync::atomic::AtomicUsize;
use std::sync::Arc;

use super::*;

/// Reverses the bytes and tags them, so a sealed value is visibly different from the plain one.
const LEGACY_TAG: u8 = 0xBB;

struct ReversingProtector {
    prepared_files: Arc<std::sync::Mutex<Vec<PathBuf>>>,
    refuse_protect: bool,
    prepared: Arc<AtomicUsize>,
    refuse_directory: bool,
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

    fn unprotect(&self, sealed: &[u8]) -> Option<Opened> {
        let (last, body) = sealed.split_last()?;
        let current = *last == 0xAA;
        (current || *last == LEGACY_TAG)
            .then(|| Opened { plain: Zeroizing::new(body.iter().rev().copied().collect()), current })
    }

    fn prepare_file(&self, file: &Path) -> io::Result<()> {
        self.prepared_files.lock().expect("the list is not poisoned").push(file.to_path_buf());
        Ok(())
    }

    fn prepare_directory(&self, _directory: &Path) -> io::Result<()> {
        self.prepared.fetch_add(1, Ordering::SeqCst);
        if self.refuse_directory {
            return Err(io::Error::other("refused"));
        }
        Ok(())
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
        SecretFiles::new(
            self.0.clone(),
            ReversingProtector { refuse_protect, prepared: Arc::new(AtomicUsize::new(0)), refuse_directory: false, prepared_files: Arc::default() },
        )
    }

    fn store_counting_preparations(&self, refuse_directory: bool) -> (SecretFiles<ReversingProtector>, Arc<AtomicUsize>) {
        let prepared = Arc::new(AtomicUsize::new(0));
        let protector = ReversingProtector { refuse_protect: false, prepared: prepared.clone(), refuse_directory, prepared_files: Arc::default() };
        (SecretFiles::new(self.0.clone(), protector), prepared)
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
    assert_eq!(store.read("host-key"), Ok(Some(b"secret bytes".to_vec())));
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
    assert_eq!(dir.store(false).read("host-key"), Ok(Some(b"old".to_vec())));
}

#[test]
fn a_failed_temporary_write_keeps_the_previous_value() {
    let dir = TestDirectory::new("failed-temporary");
    assert!(dir.store(false).write("host-key", b"old"));
    fs::create_dir(dir.0.join("host-key.tmp")).expect("a directory at the temporary name blocks the write");
    assert!(!dir.store(false).write("host-key", b"new"));
    assert_eq!(dir.store(false).read("host-key"), Ok(Some(b"old".to_vec())));
}

#[test]
fn an_unknown_name_reads_as_none() {
    let dir = TestDirectory::new("unknown");
    assert_eq!(dir.store(false).read("missing"), Ok(None));
}

#[test]
fn a_file_that_does_not_unseal_is_a_read_error_not_none() {
    let dir = TestDirectory::new("bad-seal");
    assert!(dir.store(false).write("host-key", b"secret"));
    fs::write(dir.0.join("host-key"), b"tampered").expect("the secret file is writable");
    assert_eq!(dir.store(false).read("host-key"), Err(StoreError));
}

#[test]
fn a_secret_file_that_cannot_be_opened_is_a_read_error_not_none() {
    let dir = TestDirectory::new("unopenable");
    fs::create_dir_all(dir.0.join("host-key")).expect("a directory where the secret file would be");
    assert_eq!(dir.store(false).read("host-key"), Err(StoreError));
}

#[test]
fn remove_clears_the_value_and_is_true_when_nothing_was_there() {
    let dir = TestDirectory::new("remove");
    let store = dir.store(false);
    assert!(store.write("pin", b"1"));
    assert!(store.remove("pin"));
    assert_eq!(store.read("pin"), Ok(None));
    assert!(store.remove("pin"));
}

#[test]
fn a_name_that_cannot_be_a_file_is_refused_on_write_and_read_as_an_error() {
    let dir = TestDirectory::new("bad-name");
    let store = dir.store(false);
    assert!(!store.write("../escape", b"x"));
    assert_eq!(store.read("../escape"), Err(StoreError));
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

#[test]
fn the_directory_is_restricted_once_before_the_first_write() {
    let dir = TestDirectory::new("prepare-once");
    let (store, prepared) = dir.store_counting_preparations(false);
    assert!(store.write("a", b"1"));
    assert!(store.write("b", b"2"));
    assert_eq!(prepared.load(Ordering::SeqCst), 1);
}

#[test]
fn a_directory_that_cannot_be_restricted_receives_no_secret() {
    let dir = TestDirectory::new("prepare-refused");
    let (store, _prepared) = dir.store_counting_preparations(true);
    assert!(!store.write("host-key", b"secret"));
    assert!(!dir.0.join("host-key").exists());
}

#[test]
fn a_secret_sealed_the_old_way_is_sealed_again_when_it_is_read() {
    let dir = TestDirectory::new("reseal");
    fs::create_dir_all(&dir.0).expect("the directory is made");
    fs::write(dir.0.join("host-key"), [b'y', b'e', b'k', LEGACY_TAG]).expect("an old file is written");
    let store = dir.store(false);
    assert_eq!(store.read("host-key"), Ok(Some(b"key".to_vec())));
    assert_eq!(fs::read(dir.0.join("host-key")).expect("the file is still there"), vec![b'y', b'e', b'k', 0xAA]);
}

#[test]
fn files_already_in_the_directory_are_restricted_with_it() {
    let dir = TestDirectory::new("existing-files");
    fs::create_dir_all(&dir.0).expect("the directory is made");
    fs::write(dir.0.join("older"), b"x").expect("an older secret exists");
    let store = dir.store(false);
    assert!(store.write("newer", b"1"));
    let prepared = store.protector.prepared_files.lock().expect("the list is not poisoned").clone();
    assert_eq!(prepared, vec![dir.0.join("older")]);
}
