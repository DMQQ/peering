//! The remote command a client sends to the host. See docs/protocol.md section 8.

use crate::source::{CaptureSource, NormalizedPoint};
use crate::swift_enum::base64_bytes;
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Raw values match `CGEventFlags` (shift 1 << 17 to command 1 << 20), so the host passes them straight through.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Modifiers(pub u64);

impl Modifiers {
    pub const NONE: Self = Self(0);
    pub const SHIFT: Self = Self(1 << 17);
    pub const CONTROL: Self = Self(1 << 18);
    pub const OPTION: Self = Self(1 << 19);
    pub const COMMAND: Self = Self(1 << 20);
    /// Asks for an F-key's printed action instead of the key itself.
    pub const TOP_ROW_ACTION: Self = Self(1 << 8);

    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }
}

#[derive(Debug, Error)]
#[error("unknown mouse button {0}")]
pub struct UnknownMouseButton(pub u8);

/// Serialised as the integer 0, 1 or 2.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u8", into = "u8")]
pub enum MouseButton {
    Left = 0,
    Right = 1,
    Middle = 2,
}

impl TryFrom<u8> for MouseButton {
    type Error = UnknownMouseButton;

    fn try_from(code: u8) -> Result<Self, Self::Error> {
        match code {
            0 => Ok(Self::Left),
            1 => Ok(Self::Right),
            2 => Ok(Self::Middle),
            other => Err(UnknownMouseButton(other)),
        }
    }
}

impl From<MouseButton> for u8 {
    fn from(button: MouseButton) -> Self {
        button as u8
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WindowAction {
    Close,
    Minimize,
    Zoom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SpaceDirection {
    Left,
    Right,
}

/// How a command combines with a newer one of the same kind while the send queue is busy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Coalescing {
    /// Never dropped or reordered: a lost `mouseUp` leaves a button stuck down on the host.
    None,
    ReplaceLatest,
    Accumulate,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum RemoteCommand {
    MouseMove {
        to: NormalizedPoint,
    },
    MouseDown {
        button: MouseButton,
    },
    MouseUp {
        button: MouseButton,
    },
    Scroll {
        dx: f64,
        dy: f64,
    },
    KeyDown {
        key_code: u16,
        modifiers: Modifiers,
    },
    KeyUp {
        key_code: u16,
        modifiers: Modifiers,
    },
    TextInput {
        #[serde(rename = "_0")]
        text: String,
    },
    SwitchSpace {
        direction: SpaceDirection,
    },
    SwitchToSpace {
        display: u32,
        index: i64,
    },
    JoystickMove {
        dx: f64,
        dy: f64,
    },
    SetCaptureSource {
        #[serde(rename = "_0")]
        source: CaptureSource,
    },
    LaunchApplication {
        bundle_identifier: String,
    },
    SetStreamQuality {
        fps: i64,
        bitrate_kbps: i64,
    },
    SetVideoEnabled {
        #[serde(rename = "_0")]
        enabled: bool,
    },
    RefreshSpacePreviews {},
    RefreshSourceThumbnails {},
    WatchSourceThumbnails {
        #[serde(rename = "_0")]
        watching: bool,
    },
    SetPrivacyMode {
        enabled: bool,
    },
    LockScreen {},
    RequestClipboard {},
    PushClipboard {
        text: String,
    },
    PushClipboardImage {
        #[serde(with = "base64_bytes")]
        png: Vec<u8>,
    },
    ReportDeviceOrientation {
        is_landscape: bool,
    },
    AddVirtualDisplay {
        name: String,
        width: i64,
        height: i64,
        start_landscape: bool,
    },
    RemoveVirtualDisplay {
        #[serde(rename = "displayID")]
        display_id: u32,
    },
    RenameVirtualDisplay {
        #[serde(rename = "displayID")]
        display_id: u32,
        name: String,
    },
    PerformWindowAction {
        #[serde(rename = "windowID")]
        window_id: u32,
        action: WindowAction,
    },
    OpenNewWindow {
        bundle_identifier: String,
    },
}

impl RemoteCommand {
    pub fn coalescing(&self) -> Coalescing {
        match self {
            Self::MouseMove { .. } | Self::ReportDeviceOrientation { .. } => Coalescing::ReplaceLatest,
            Self::JoystickMove { .. } | Self::Scroll { .. } => Coalescing::Accumulate,
            Self::MouseDown { .. }
            | Self::MouseUp { .. }
            | Self::KeyDown { .. }
            | Self::KeyUp { .. }
            | Self::TextInput { .. }
            | Self::SwitchSpace { .. }
            | Self::SwitchToSpace { .. }
            | Self::SetCaptureSource { .. }
            | Self::LaunchApplication { .. }
            | Self::SetStreamQuality { .. }
            | Self::SetVideoEnabled { .. }
            | Self::RefreshSpacePreviews {}
            | Self::RefreshSourceThumbnails {}
            | Self::WatchSourceThumbnails { .. }
            | Self::SetPrivacyMode { .. }
            | Self::LockScreen {}
            | Self::RequestClipboard {}
            | Self::PushClipboard { .. }
            | Self::PushClipboardImage { .. }
            | Self::AddVirtualDisplay { .. }
            | Self::RemoveVirtualDisplay { .. }
            | Self::RenameVirtualDisplay { .. }
            | Self::PerformWindowAction { .. }
            | Self::OpenNewWindow { .. } => Coalescing::None,
        }
    }

    /// Must survive a full send queue, because losing it would leave the host stuck.
    pub fn is_critical(&self) -> bool {
        matches!(
            self,
            Self::MouseDown { .. }
                | Self::MouseUp { .. }
                | Self::KeyDown { .. }
                | Self::KeyUp { .. }
                | Self::SetCaptureSource { .. }
                | Self::LaunchApplication { .. }
                | Self::SetPrivacyMode { .. }
                | Self::LockScreen {}
                | Self::PushClipboard { .. }
                | Self::PushClipboardImage { .. }
                | Self::SetVideoEnabled { .. }
        )
    }

    /// Pointer and keyboard input, which a host in observe mode refuses. Stream and session controls stay allowed.
    pub fn is_user_input(&self) -> bool {
        matches!(
            self,
            Self::MouseMove { .. }
                | Self::MouseDown { .. }
                | Self::MouseUp { .. }
                | Self::Scroll { .. }
                | Self::KeyDown { .. }
                | Self::KeyUp { .. }
                | Self::TextInput { .. }
                | Self::SwitchSpace { .. }
                | Self::SwitchToSpace { .. }
                | Self::JoystickMove { .. }
        )
    }
}

#[cfg(test)]
mod tests;
