//! The app icon as 64 by 64 RGBA, for the tray and the window. The executable's own icon is `assets/app.ico`.

pub const SIDE: u32 = 64;
pub const RGBA: &[u8] = include_bytes!("../../assets/icon-64.rgba");
