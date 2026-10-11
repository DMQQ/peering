//! Host session logic: handshake, liveness and command dispatch.

pub mod actions;
pub mod deps;
pub mod dispatch;
pub mod handshake;
pub mod liveness;
pub mod state;

#[cfg(test)]
mod test_support;
