//! The random bytes that are mixed into every seal of this install's secrets, so a process that knows how the host seals
//! (the source is public) still cannot open a copy of a secret file without also reading the install's own entropy.

use crate::ports::secret_store::SecretStore;

/// The name the entropy is stored under, next to the secrets it protects. The secret store that uses the entropy refuses
/// this name, so a secret cannot overwrite it.
pub const ENTROPY_SECRET_NAME: &str = "install-entropy";
pub const ENTROPY_BYTES: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum EntropyError {
    /// An entropy is stored but cannot be read or is the wrong size. A new one is not minted over it: the secrets sealed
    /// with it would be lost for good.
    #[error("the install's sealing entropy exists but cannot be read")]
    Unreadable,
    #[error("the install's sealing entropy could not be saved")]
    CouldNotSave,
    #[error("no random bytes were available for the install's sealing entropy")]
    NoRandomness,
}

/// The stored entropy, or a new one saved first when this install has none. `fill_random` fills the slice with random bytes
/// and says whether it could.
pub fn load_or_mint(store: &dyn SecretStore, fill_random: impl FnOnce(&mut [u8]) -> bool) -> Result<Vec<u8>, EntropyError> {
    match store.read(ENTROPY_SECRET_NAME) {
        Err(_) => Err(EntropyError::Unreadable),
        Ok(Some(entropy)) if entropy.len() == ENTROPY_BYTES => Ok(entropy),
        Ok(Some(_)) => Err(EntropyError::Unreadable),
        Ok(None) => {
            let mut entropy = vec![0u8; ENTROPY_BYTES];
            if !fill_random(&mut entropy) {
                return Err(EntropyError::NoRandomness);
            }
            if !store.write(ENTROPY_SECRET_NAME, &entropy) {
                return Err(EntropyError::CouldNotSave);
            }
            Ok(entropy)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::secret_store::InMemorySecretStore;

    fn counting(bytes: u8) -> impl FnOnce(&mut [u8]) -> bool {
        move |slice| {
            slice.fill(bytes);
            true
        }
    }

    #[test]
    fn an_install_without_entropy_mints_and_saves_one() {
        let store = InMemorySecretStore::default();
        let entropy = load_or_mint(&store, counting(7)).expect("a new entropy");
        assert_eq!(entropy, vec![7; ENTROPY_BYTES]);
        assert_eq!(store.read(ENTROPY_SECRET_NAME), Ok(Some(entropy)));
    }

    #[test]
    fn the_stored_entropy_is_reused_and_not_replaced() {
        let store = InMemorySecretStore::default();
        load_or_mint(&store, counting(7)).expect("a new entropy");
        assert_eq!(load_or_mint(&store, counting(9)), Ok(vec![7; ENTROPY_BYTES]));
    }

    #[test]
    fn an_entropy_that_cannot_be_read_is_never_replaced() {
        let store = InMemorySecretStore::default();
        load_or_mint(&store, counting(7)).expect("a new entropy");
        store.set_fail_reads(true);
        assert_eq!(load_or_mint(&store, counting(9)), Err(EntropyError::Unreadable));
        store.set_fail_reads(false);
        assert_eq!(store.read(ENTROPY_SECRET_NAME), Ok(Some(vec![7; ENTROPY_BYTES])));
    }

    #[test]
    fn an_entropy_of_the_wrong_size_is_unreadable_not_replaced() {
        let store = InMemorySecretStore::default();
        assert!(store.write(ENTROPY_SECRET_NAME, b"short"));
        assert_eq!(load_or_mint(&store, counting(9)), Err(EntropyError::Unreadable));
        assert_eq!(store.read(ENTROPY_SECRET_NAME), Ok(Some(b"short".to_vec())));
    }

    #[test]
    fn no_randomness_mints_nothing() {
        let store = InMemorySecretStore::default();
        assert_eq!(load_or_mint(&store, |_| false), Err(EntropyError::NoRandomness));
        assert_eq!(store.read(ENTROPY_SECRET_NAME), Ok(None));
    }

    #[test]
    fn an_entropy_that_cannot_be_saved_is_an_error() {
        let store = InMemorySecretStore::default();
        store.set_fail_writes(true);
        assert_eq!(load_or_mint(&store, counting(7)), Err(EntropyError::CouldNotSave));
    }
}
