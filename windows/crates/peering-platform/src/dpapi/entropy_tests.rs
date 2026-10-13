use std::fs;
use std::path::PathBuf;

use peering_core::ports::secret_store::{SecretStore, StoreError};

use super::*;

/// Puts the entropy in front of the plain bytes, so a seal opens only with the entropy it was made with.
#[derive(Clone)]
struct EntropyEchoingSealer;

impl Sealer for EntropyEchoingSealer {
    fn seal(&self, plain: &[u8], entropy: Option<&[u8]>) -> Option<Vec<u8>> {
        let entropy = entropy.unwrap_or_default();
        let mut sealed = vec![u8::try_from(entropy.len()).ok()?];
        sealed.extend_from_slice(entropy);
        sealed.extend(plain.iter().rev());
        Some(sealed)
    }

    fn open(&self, sealed: &[u8], entropy: Option<&[u8]>) -> Option<Zeroizing<Vec<u8>>> {
        let entropy = entropy.unwrap_or_default();
        let (length, rest) = sealed.split_first()?;
        let (stored, body) = rest.split_at_checked(usize::from(*length))?;
        (stored == entropy).then(|| Zeroizing::new(body.iter().rev().copied().collect()))
    }
}

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new(test: &str) -> Self {
        let path = std::env::temp_dir().join(format!("peering-entropy-{test}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        Self(path)
    }

    fn open(&self, byte: u8) -> Result<SecretFiles<EntropyProtector<EntropyEchoingSealer>>, EntropyError> {
        open_store(self.0.clone(), EntropyEchoingSealer, |slice| {
            slice.fill(byte);
            true
        })
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// A store as the build before per-install entropy made it: every seal mixed with the fixed value.
fn legacy_store(dir: &TestDirectory) -> SecretFiles<EntropyProtector<EntropyEchoingSealer>> {
    SecretFiles::new(dir.0.clone(), EntropyProtector::new(EntropyEchoingSealer, LEGACY_ENTROPY.to_vec()))
}

#[test]
fn a_secret_round_trips_and_the_entropy_is_minted_once_per_install() {
    let dir = TestDirectory::new("round-trip");
    let first = dir.open(1).expect("the store opens");
    assert!(first.write("host-key", b"secret"));
    let second = dir.open(2).expect("the store opens again");
    assert_eq!(second.read("host-key"), Ok(Some(b"secret".to_vec())), "the entropy of the first open is the one kept");
}

#[test]
fn a_secret_file_copied_to_another_install_does_not_open() {
    let one = TestDirectory::new("install-one");
    let other = TestDirectory::new("install-other");
    assert!(one.open(1).expect("opens").write("host-key", b"secret"));
    let elsewhere = other.open(2).expect("opens");
    fs::copy(one.0.join("host-key"), other.0.join("host-key")).expect("the file is copied");
    assert_eq!(elsewhere.read("host-key"), Err(StoreError));
}

#[test]
fn a_process_that_knows_only_the_fixed_value_cannot_open_a_current_secret() {
    let dir = TestDirectory::new("fixed-value");
    assert!(dir.open(1).expect("opens").write("host-key", b"secret"));
    assert_eq!(legacy_store(&dir).read("host-key"), Err(StoreError));
}

#[test]
fn secrets_sealed_with_the_fixed_value_or_with_nothing_are_sealed_again_when_the_store_opens() {
    let dir = TestDirectory::new("migration");
    assert!(legacy_store(&dir).write("host-key", b"fixed"));
    fs::write(dir.0.join("device-id"), EntropyEchoingSealer.seal(b"bare", None).expect("sealed")).expect("an older file is written");

    let store = dir.open(5).expect("the store opens");

    let host_key = fs::read(dir.0.join("host-key")).expect("the file is there");
    let device_id = fs::read(dir.0.join("device-id")).expect("the file is there");
    assert_eq!(EntropyEchoingSealer.open(&host_key, Some(&[5; 32])).as_deref().map(Vec::as_slice), Some(b"fixed".as_slice()));
    assert_eq!(EntropyEchoingSealer.open(&device_id, Some(&[5; 32])).as_deref().map(Vec::as_slice), Some(b"bare".as_slice()));
    assert_eq!(store.read("host-key"), Ok(Some(b"fixed".to_vec())));
}

#[test]
fn migration_counts_what_it_sealed_again_and_leaves_current_and_unopenable_files_alone() {
    let dir = TestDirectory::new("migration-count");
    assert!(dir.open(5).expect("opens").write("current", b"now"));
    assert!(legacy_store(&dir).write("old", b"then"));
    fs::write(dir.0.join("broken"), [200u8, 1, 2]).expect("a file nobody can open");
    let broken_before = fs::read(dir.0.join("broken")).expect("the file is there");

    let store = dir.open(5).expect("opens");

    assert_eq!(store.migrate(), 0, "the first open already sealed the old file again");
    assert_eq!(fs::read(dir.0.join("broken")).expect("the file is there"), broken_before);
}

#[test]
fn an_entropy_that_cannot_be_opened_stops_the_store_and_touches_no_secret() {
    let dir = TestDirectory::new("lost-entropy");
    assert!(dir.open(1).expect("opens").write("host-key", b"secret"));
    fs::write(dir.0.join(ENTROPY_SECRET_NAME), [200u8, 1, 2]).expect("the entropy file is damaged");
    let sealed_before = fs::read(dir.0.join("host-key")).expect("the file is there");

    assert!(matches!(dir.open(9), Err(EntropyError::Unreadable)));

    assert_eq!(fs::read(dir.0.join("host-key")).expect("the file is there"), sealed_before);
}

#[test]
fn a_secret_cannot_be_stored_under_the_name_of_the_entropy() {
    let dir = TestDirectory::new("reserved");
    let store = dir.open(1).expect("opens");
    assert!(!store.write(ENTROPY_SECRET_NAME, b"overwrite"));
    assert_eq!(store.read(ENTROPY_SECRET_NAME), Err(StoreError));
    assert!(!store.remove(ENTROPY_SECRET_NAME));
    assert!(dir.open(2).is_ok(), "the entropy is still readable");
}

#[test]
fn no_random_bytes_means_no_store() {
    let dir = TestDirectory::new("no-random");
    assert!(matches!(open_store(dir.0.clone(), EntropyEchoingSealer, |_| false), Err(EntropyError::NoRandomness)));
}
