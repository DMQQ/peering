//! Sealing with an entropy that belongs to this install. The OS call is behind `Sealer`, so the rules (which entropy
//! seals, which earlier ways still open, when the entropy is minted) run under test on any OS.

use std::io;
use std::path::{Path, PathBuf};

use peering_core::install_entropy::{load_or_mint, EntropyError, ENTROPY_SECRET_NAME};
use zeroize::Zeroizing;

use super::{Opened, Protector, SecretFiles};

/// What every seal was mixed with before each install had an entropy of its own. It is in the source, so it keeps nothing
/// out of a process that reads the source; it is kept only to open and re-seal what was sealed with it.
pub const LEGACY_ENTROPY: &[u8] = b"pl.dmq.peering.host secret store v1";

/// The operating system's seal, with the entropy it is given mixed in.
pub trait Sealer: Clone {
    fn seal(&self, plain: &[u8], entropy: Option<&[u8]>) -> Option<Vec<u8>>;
    fn open(&self, sealed: &[u8], entropy: Option<&[u8]>) -> Option<Zeroizing<Vec<u8>>>;

    fn prepare_directory(&self, _directory: &Path) -> io::Result<()> {
        Ok(())
    }

    fn prepare_file(&self, _file: &Path) -> io::Result<()> {
        Ok(())
    }
}

/// Seals with no entropy at all: for the file that holds the install's entropy, which cannot be sealed with itself.
#[derive(Clone)]
pub struct UnkeyedProtector<S: Sealer>(pub S);

impl<S: Sealer> Protector for UnkeyedProtector<S> {
    fn protect(&self, plain: &[u8]) -> Option<Vec<u8>> {
        self.0.seal(plain, None)
    }

    fn unprotect(&self, sealed: &[u8]) -> Option<Opened> {
        self.0.open(sealed, None).map(|plain| Opened { plain, current: true })
    }

    fn prepare_directory(&self, directory: &Path) -> io::Result<()> {
        self.0.prepare_directory(directory)
    }

    fn prepare_file(&self, file: &Path) -> io::Result<()> {
        self.0.prepare_file(file)
    }
}

/// Seals with the install's entropy. A secret sealed an earlier way (the fixed entropy, or none) still opens and is
/// reported as not current, so the store seals it again.
pub struct EntropyProtector<S: Sealer> {
    sealer: S,
    entropy: Zeroizing<Vec<u8>>,
}

impl<S: Sealer> EntropyProtector<S> {
    pub fn new(sealer: S, entropy: Vec<u8>) -> Self {
        Self { sealer, entropy: Zeroizing::new(entropy) }
    }
}

impl<S: Sealer> Protector for EntropyProtector<S> {
    fn protect(&self, plain: &[u8]) -> Option<Vec<u8>> {
        self.sealer.seal(plain, Some(&self.entropy))
    }

    fn unprotect(&self, sealed: &[u8]) -> Option<Opened> {
        if let Some(plain) = self.sealer.open(sealed, Some(&self.entropy)) {
            return Some(Opened { plain, current: true });
        }
        let earlier = self.sealer.open(sealed, Some(LEGACY_ENTROPY)).or_else(|| self.sealer.open(sealed, None));
        earlier.map(|plain| Opened { plain, current: false })
    }

    fn prepare_directory(&self, directory: &Path) -> io::Result<()> {
        self.sealer.prepare_directory(directory)
    }

    fn prepare_file(&self, file: &Path) -> io::Result<()> {
        self.sealer.prepare_file(file)
    }
}

/// The secret store for `directory`: the install's entropy is loaded, or minted and saved on first use, and every secret
/// sealed an earlier way is sealed again with it before the store is handed out. Fails, without touching any secret, when
/// the entropy exists and cannot be read.
pub fn open_store<S: Sealer>(
    directory: PathBuf,
    sealer: S,
    fill_random: impl FnOnce(&mut [u8]) -> bool,
) -> Result<SecretFiles<EntropyProtector<S>>, EntropyError> {
    let entropy_file = SecretFiles::new(directory.clone(), UnkeyedProtector(sealer.clone()));
    let entropy = load_or_mint(&entropy_file, fill_random)?;
    let store = SecretFiles::new(directory, EntropyProtector::new(sealer, entropy)).reserving(ENTROPY_SECRET_NAME);
    store.migrate();
    Ok(store)
}

#[cfg(test)]
#[path = "entropy_tests.rs"]
mod tests;
