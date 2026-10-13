//! Starting over with a paired list that cannot be read. The unreadable bytes are copied to the backup name first and the
//! list is replaced only once the copy is safe, so the one thing a reset can lose is a list nobody could read anyway, and
//! even that stays on disk under the backup name.

use crate::ports::secret_store::SecretStore;

const EMPTY_LIST: &[u8] = b"[]";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResetOutcome {
    /// The unreadable list was kept under the backup name and a fresh empty list stands in its place.
    Done,
    /// The stored list reads fine, so there is nothing to reset and nothing was touched.
    NotNeeded,
    /// Nothing is stored under the list name.
    NothingStored,
    ReadFailed,
    /// The copy could not be written, so the list was left as it was.
    BackupFailed,
    /// The copy is safe but the fresh list could not be written; the unreadable one is still in place.
    ReplaceFailed,
}

/// Moves the stored `list` to `backup` and starts a fresh empty list, when `readable` says the stored bytes are not a list.
pub fn reset_unreadable(store: &dyn SecretStore, list: &str, backup: &str, readable: impl Fn(&[u8]) -> bool) -> ResetOutcome {
    let bytes = match store.read(list) {
        Err(_) => return ResetOutcome::ReadFailed,
        Ok(None) => return ResetOutcome::NothingStored,
        Ok(Some(bytes)) => bytes,
    };
    if readable(&bytes) {
        return ResetOutcome::NotNeeded;
    }
    if !store.write(backup, &bytes) {
        return ResetOutcome::BackupFailed;
    }
    if !store.write(list, EMPTY_LIST) {
        return ResetOutcome::ReplaceFailed;
    }
    ResetOutcome::Done
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::secret_store::InMemorySecretStore;

    const LIST: &str = "pairedDevices";
    const BACKUP: &str = "pairedDevices-bad";

    fn never_readable(_: &[u8]) -> bool {
        false
    }

    fn store_with(bytes: &[u8]) -> InMemorySecretStore {
        let store = InMemorySecretStore::default();
        assert!(store.write(LIST, bytes));
        store
    }

    #[test]
    fn an_unreadable_list_is_moved_to_the_backup_and_replaced_by_an_empty_one() {
        let store = store_with(b"garbage");
        assert_eq!(reset_unreadable(&store, LIST, BACKUP, never_readable), ResetOutcome::Done);
        assert_eq!(store.read(BACKUP), Ok(Some(b"garbage".to_vec())));
        assert_eq!(store.read(LIST), Ok(Some(b"[]".to_vec())));
    }

    #[test]
    fn a_list_that_reads_fine_is_never_touched() {
        let store = store_with(b"[]");
        assert_eq!(reset_unreadable(&store, LIST, BACKUP, |_| true), ResetOutcome::NotNeeded);
        assert_eq!(store.read(LIST), Ok(Some(b"[]".to_vec())));
        assert_eq!(store.read(BACKUP), Ok(None));
    }

    #[test]
    fn a_backup_that_cannot_be_written_leaves_the_list_where_it_was() {
        let store = store_with(b"garbage");
        store.set_fail_writes(true);
        assert_eq!(reset_unreadable(&store, LIST, BACKUP, never_readable), ResetOutcome::BackupFailed);
        assert_eq!(store.read(LIST), Ok(Some(b"garbage".to_vec())));
    }

    #[test]
    fn a_store_that_cannot_be_read_is_reported_and_changes_nothing() {
        let store = store_with(b"garbage");
        store.set_fail_reads(true);
        assert_eq!(reset_unreadable(&store, LIST, BACKUP, never_readable), ResetOutcome::ReadFailed);
        store.set_fail_reads(false);
        assert_eq!(store.read(LIST), Ok(Some(b"garbage".to_vec())));
        assert_eq!(store.read(BACKUP), Ok(None));
    }

    #[test]
    fn nothing_stored_is_not_a_reset() {
        let store = InMemorySecretStore::default();
        assert_eq!(reset_unreadable(&store, LIST, BACKUP, never_readable), ResetOutcome::NothingStored);
    }
}
