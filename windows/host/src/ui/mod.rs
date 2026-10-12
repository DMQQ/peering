//! The tray and the pairing window. `model` holds every decision and is tested on any OS; `tray` and `app` only draw
//! what the models say and are compiled for Windows only.

pub mod model;

#[cfg(windows)]
mod app;
#[cfg(windows)]
mod tray;

#[cfg(windows)]
pub use app::run;
