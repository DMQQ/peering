//! Peering wire protocol: framing, message models, pairing maths and video sealing. No OS dependency.

pub mod chunks;
pub mod framing;
pub mod replay;
pub mod sas;
pub mod vectors_dir;
