//! Locking that carries on after a panic elsewhere. The data behind these locks is rebuilt or reset by the code that caught
//! the panic, so refusing to lock would turn one failed pass into a dead host.

use std::sync::{Mutex, MutexGuard, PoisonError};

pub fn lock_ignoring_poison<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
