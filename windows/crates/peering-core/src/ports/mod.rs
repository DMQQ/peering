//! Traits the host core calls out through. `peering-platform` implements them per OS; `fakes` implements them for tests.

pub mod capture;
pub mod clock;
pub mod encoder;
pub mod input;
pub mod secret_store;
pub mod stream;
pub mod system;
