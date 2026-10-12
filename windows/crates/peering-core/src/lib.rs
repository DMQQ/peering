//! Host session logic with no operating system dependency. Ports and fakes live in `ports`.

pub mod fakes;
pub mod ports;
pub mod settings;
pub mod admission;
pub mod catalogue;
pub mod files;
pub mod notice;
pub mod outbound;
pub mod pairing;
pub mod push_tokens;
pub mod relay;
pub mod session;
pub mod supervision;
pub mod terminal;
pub mod video;
