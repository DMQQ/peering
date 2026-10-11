//! In-memory implementations of the ports, usable from any crate's tests.

use std::sync::{Mutex, MutexGuard, PoisonError};

pub mod capture;
pub mod clock;
pub mod encoder;
pub mod input;
pub mod secret_store;
pub mod stream;

/// Fakes hold no invariant a panicking test could break, so a poisoned lock is read through.
pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
