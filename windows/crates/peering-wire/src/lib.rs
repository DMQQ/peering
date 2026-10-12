//! Peering wire protocol: framing, message models, pairing maths and video sealing. No OS dependency.

pub mod agent;
pub mod annexb;
pub mod chunks;
pub mod command;
pub mod drop_policy;
pub mod fallback;
pub mod files;
pub mod framing;
pub mod handshake;
pub mod keymap;
pub mod pairing_payload;
pub mod path_segment;
pub mod quality;
pub mod relay_messages;
pub mod relay_proof;
pub mod replay;
pub mod sas;
pub mod sealing;
pub mod source;
pub mod swift_enum;
pub mod terminal;
pub mod transform;
pub mod vectors_dir;
pub mod video;
pub mod video_transport;
