//! Locking that carries on after a panic elsewhere. The data behind these locks is rebuilt or reset by the code that caught
//! the panic, so refusing to lock would turn one failed pass into a dead host.

use std::sync::{Mutex, MutexGuard, PoisonError};

/// Locks `mutex`, clearing a poisoning left by a panic. The flag says whether it was poisoned, so the caller can report it
/// once: the poison is gone afterwards, and only a new panic brings it back.
pub fn lock_clearing_poison<T>(mutex: &Mutex<T>) -> (MutexGuard<'_, T>, bool) {
    match mutex.lock() {
        Ok(guard) => (guard, false),
        Err(poisoned) => {
            mutex.clear_poison();
            (poisoned.into_inner(), true)
        }
    }
}

pub fn lock_ignoring_poison<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use std::panic::{catch_unwind, AssertUnwindSafe};

    use super::*;

    #[test]
    fn a_poisoned_lock_is_recovered_and_reported_once() {
        let mutex = Mutex::new(5);
        let _ = catch_unwind(AssertUnwindSafe(|| {
            let _guard = mutex.lock().expect("not poisoned yet");
            panic!("a pass died holding the lock");
        }));
        assert!(mutex.is_poisoned());
        let (first, recovered) = lock_clearing_poison(&mutex);
        assert_eq!((*first, recovered), (5, true));
        drop(first);
        let (_second, recovered_again) = lock_clearing_poison(&mutex);
        assert!(!recovered_again, "the poison was cleared by the first lock");
    }
}
