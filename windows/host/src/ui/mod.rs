//! The tray and the pairing window. `model` holds every decision and is tested on any OS; `tray` and `app` only draw
//! what the models say and are compiled for Windows only.

pub mod jobs;
pub mod model;
pub mod qr;
pub mod settings;

#[cfg(windows)]
mod app;
#[cfg(windows)]
mod icon;
#[cfg(windows)]
mod pairing;
#[cfg(windows)]
mod settings_view;
#[cfg(windows)]
mod tray;

#[cfg(windows)]
pub use app::run;
