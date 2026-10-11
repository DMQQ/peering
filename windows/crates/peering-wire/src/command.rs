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
mod tests {
    use super::*;
    use crate::vectors_dir::load;
    use serde_json::{json, Value};

    /// Numbers compared as f64, since serde_json writes `0.0` where Swift writes `0`.
    fn numbers_as_f64(value: &Value) -> Value {
        match value {
            Value::Number(number) => json!(number.as_f64()),
            Value::Array(items) => Value::Array(items.iter().map(numbers_as_f64).collect()),
            Value::Object(map) => Value::Object(map.iter().map(|(k, v)| (k.clone(), numbers_as_f64(v))).collect()),
            other => other.clone(),
        }
    }

    /// The key of the one-key object a command serialises to, which is its Swift case name.
    fn case_name(command: &RemoteCommand) -> String {
        let value = serde_json::to_value(command).unwrap();
        value.as_object().unwrap().keys().next().unwrap().clone()
    }

    fn every_case() -> Vec<RemoteCommand> {
        vec![
            RemoteCommand::MouseMove { to: NormalizedPoint { x: 0.5, y: 0.5 } },
            RemoteCommand::MouseDown { button: MouseButton::Left },
            RemoteCommand::MouseUp { button: MouseButton::Left },
            RemoteCommand::Scroll { dx: 0.0, dy: -1.0 },
            RemoteCommand::KeyDown { key_code: 36, modifiers: Modifiers::NONE },
            RemoteCommand::KeyUp { key_code: 36, modifiers: Modifiers::NONE },
            RemoteCommand::TextInput { text: "a".into() },
            RemoteCommand::SwitchSpace { direction: SpaceDirection::Left },
            RemoteCommand::SwitchToSpace { display: 1, index: 2 },
            RemoteCommand::JoystickMove { dx: 0.0, dy: 0.0 },
            RemoteCommand::SetCaptureSource { source: CaptureSource::Display { id: 1 } },
            RemoteCommand::LaunchApplication { bundle_identifier: "x".into() },
            RemoteCommand::SetStreamQuality { fps: 0, bitrate_kbps: 8000 },
            RemoteCommand::SetVideoEnabled { enabled: false },
            RemoteCommand::RefreshSpacePreviews {},
            RemoteCommand::RefreshSourceThumbnails {},
            RemoteCommand::WatchSourceThumbnails { watching: true },
            RemoteCommand::SetPrivacyMode { enabled: true },
            RemoteCommand::LockScreen {},
            RemoteCommand::RequestClipboard {},
            RemoteCommand::PushClipboard { text: "x".into() },
            RemoteCommand::PushClipboardImage { png: vec![1] },
            RemoteCommand::ReportDeviceOrientation { is_landscape: true },
            RemoteCommand::AddVirtualDisplay { name: String::new(), width: 1170, height: 2532, start_landscape: false },
            RemoteCommand::RemoveVirtualDisplay { display_id: 5 },
            RemoteCommand::RenameVirtualDisplay { display_id: 5, name: "n".into() },
            RemoteCommand::PerformWindowAction { window_id: 7, action: WindowAction::Close },
            RemoteCommand::OpenNewWindow { bundle_identifier: "x".into() },
        ]
    }

    /// Asserts the command encodes to `expected` and decodes back from it.
    fn encodes_as(command: RemoteCommand, expected: &str) {
        let expected: Value = serde_json::from_str(expected).unwrap();
        let written = serde_json::to_value(&command).unwrap();
        assert_eq!(numbers_as_f64(&written), numbers_as_f64(&expected));
        assert_eq!(serde_json::from_value::<RemoteCommand>(expected).unwrap(), command);
    }

    #[test]
    fn every_command_vector_round_trips() {
        let vectors = load("messages.json");
        let mut checked = 0;
        for case in vectors["cases"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            if !name.starts_with("command ") {
                continue;
            }
            let original: Value = serde_json::from_str(case["json"].as_str().unwrap()).unwrap();
            let command: RemoteCommand = serde_json::from_value(original.clone()).unwrap_or_else(|e| panic!("{name}: {e}"));
            let written = serde_json::to_value(&command).unwrap();
            assert_eq!(numbers_as_f64(&written), numbers_as_f64(&original), "{name}");
            checked += 1;
        }
        assert_eq!(checked, 9);
    }

    #[test]
    fn mouse_moves_and_buttons_encode_as_documented() {
        encodes_as(RemoteCommand::MouseMove { to: NormalizedPoint { x: 0.5, y: 0.25 } }, r#"{"mouseMove":{"to":{"x":0.5,"y":0.25}}}"#);
        encodes_as(RemoteCommand::MouseDown { button: MouseButton::Middle }, r#"{"mouseDown":{"button":2}}"#);
        encodes_as(RemoteCommand::MouseUp { button: MouseButton::Right }, r#"{"mouseUp":{"button":1}}"#);
    }

    #[test]
    fn an_unknown_mouse_button_is_an_error() {
        assert!(serde_json::from_str::<RemoteCommand>(r#"{"mouseDown":{"button":5}}"#).is_err());
    }

    #[test]
    fn scroll_and_joystick_encode_their_deltas() {
        encodes_as(RemoteCommand::Scroll { dx: 0.0, dy: -12.5 }, r#"{"scroll":{"dx":0,"dy":-12.5}}"#);
        encodes_as(RemoteCommand::JoystickMove { dx: 1.0, dy: -1.0 }, r#"{"joystickMove":{"dx":1,"dy":-1}}"#);
    }

    #[test]
    fn keys_encode_keycode_and_modifier_bits() {
        let command = RemoteCommand::KeyUp { key_code: 36, modifiers: Modifiers::COMMAND };
        encodes_as(command, r#"{"keyUp":{"keyCode":36,"modifiers":1048576}}"#);
        assert!(Modifiers::COMMAND.contains(Modifiers::COMMAND));
        assert!(!Modifiers::SHIFT.contains(Modifiers::COMMAND));
    }

    #[test]
    fn text_and_clipboard_encode_their_payloads() {
        encodes_as(RemoteCommand::TextInput { text: "hi".into() }, r#"{"textInput":{"_0":"hi"}}"#);
        encodes_as(RemoteCommand::PushClipboard { text: "x".into() }, r#"{"pushClipboard":{"text":"x"}}"#);
        encodes_as(RemoteCommand::PushClipboardImage { png: vec![1, 2] }, r#"{"pushClipboardImage":{"png":"AQI="}}"#);
        encodes_as(RemoteCommand::RequestClipboard {}, r#"{"requestClipboard":{}}"#);
    }

    #[test]
    fn spaces_encode_direction_and_index() {
        encodes_as(RemoteCommand::SwitchSpace { direction: SpaceDirection::Right }, r#"{"switchSpace":{"direction":"right"}}"#);
        encodes_as(RemoteCommand::SwitchToSpace { display: 1, index: 2 }, r#"{"switchToSpace":{"display":1,"index":2}}"#);
    }

    #[test]
    fn capture_source_commands_encode_the_source() {
        encodes_as(
            RemoteCommand::SetCaptureSource { source: CaptureSource::Window { id: 7 } },
            r#"{"setCaptureSource":{"_0":{"window":{"_0":7}}}}"#,
        );
        encodes_as(
            RemoteCommand::SetCaptureSource { source: CaptureSource::Application { pid: 42 } },
            r#"{"setCaptureSource":{"_0":{"application":{"_0":42}}}}"#,
        );
        encodes_as(RemoteCommand::LaunchApplication { bundle_identifier: "com.x".into() }, r#"{"launchApplication":{"bundleIdentifier":"com.x"}}"#);
        encodes_as(RemoteCommand::OpenNewWindow { bundle_identifier: "com.x".into() }, r#"{"openNewWindow":{"bundleIdentifier":"com.x"}}"#);
    }

    #[test]
    fn stream_controls_encode_quality_and_visibility() {
        encodes_as(RemoteCommand::SetStreamQuality { fps: 30, bitrate_kbps: 0 }, r#"{"setStreamQuality":{"fps":30,"bitrateKbps":0}}"#);
        encodes_as(RemoteCommand::SetVideoEnabled { enabled: true }, r#"{"setVideoEnabled":{"_0":true}}"#);
        encodes_as(RemoteCommand::WatchSourceThumbnails { watching: false }, r#"{"watchSourceThumbnails":{"_0":false}}"#);
        encodes_as(RemoteCommand::RefreshSourceThumbnails {}, r#"{"refreshSourceThumbnails":{}}"#);
        encodes_as(RemoteCommand::RefreshSpacePreviews {}, r#"{"refreshSpacePreviews":{}}"#);
    }

    #[test]
    fn privacy_lock_and_orientation_encode_their_flags() {
        encodes_as(RemoteCommand::SetPrivacyMode { enabled: true }, r#"{"setPrivacyMode":{"enabled":true}}"#);
        encodes_as(RemoteCommand::LockScreen {}, r#"{"lockScreen":{}}"#);
        encodes_as(RemoteCommand::ReportDeviceOrientation { is_landscape: true }, r#"{"reportDeviceOrientation":{"isLandscape":true}}"#);
    }

    #[test]
    fn virtual_display_commands_use_the_capital_id_key() {
        encodes_as(
            RemoteCommand::AddVirtualDisplay { name: String::new(), width: 1170, height: 2532, start_landscape: false },
            r#"{"addVirtualDisplay":{"name":"","width":1170,"height":2532,"startLandscape":false}}"#,
        );
        encodes_as(RemoteCommand::RemoveVirtualDisplay { display_id: 5 }, r#"{"removeVirtualDisplay":{"displayID":5}}"#);
        encodes_as(
            RemoteCommand::RenameVirtualDisplay { display_id: 5, name: "Desk".into() },
            r#"{"renameVirtualDisplay":{"displayID":5,"name":"Desk"}}"#,
        );
    }

    #[test]
    fn window_actions_encode_the_window_id_and_action_name() {
        encodes_as(
            RemoteCommand::PerformWindowAction { window_id: 7, action: WindowAction::Minimize },
            r#"{"performWindowAction":{"windowID":7,"action":"minimize"}}"#,
        );
    }

    #[test]
    fn an_unknown_case_is_an_error_not_a_panic() {
        assert!(serde_json::from_str::<RemoteCommand>(r#"{"somethingNew":{}}"#).is_err());
    }

    #[test]
    fn only_moves_and_orientation_replace_and_only_deltas_accumulate() {
        for command in every_case() {
            let expected = match case_name(&command).as_str() {
                "mouseMove" | "reportDeviceOrientation" => Coalescing::ReplaceLatest,
                "scroll" | "joystickMove" => Coalescing::Accumulate,
                _ => Coalescing::None,
            };
            assert_eq!(command.coalescing(), expected, "{}", case_name(&command));
        }
    }

    #[test]
    fn press_and_release_are_never_coalesced() {
        for command in [
            RemoteCommand::MouseDown { button: MouseButton::Left },
            RemoteCommand::MouseUp { button: MouseButton::Left },
            RemoteCommand::KeyDown { key_code: 1, modifiers: Modifiers::NONE },
            RemoteCommand::KeyUp { key_code: 1, modifiers: Modifiers::NONE },
        ] {
            assert_eq!(command.coalescing(), Coalescing::None);
        }
    }

    #[test]
    fn critical_and_user_input_follow_the_swift_lists() {
        let critical: Vec<String> = every_case().iter().filter(|c| c.is_critical()).map(case_name).collect();
        assert_eq!(
            critical,
            ["mouseDown", "mouseUp", "keyDown", "keyUp", "setCaptureSource", "launchApplication", "setVideoEnabled", "setPrivacyMode", "lockScreen", "pushClipboard", "pushClipboardImage"]
        );
        let input: Vec<String> = every_case().iter().filter(|c| c.is_user_input()).map(case_name).collect();
        assert_eq!(input, ["mouseMove", "mouseDown", "mouseUp", "scroll", "keyDown", "keyUp", "textInput", "switchSpace", "switchToSpace", "joystickMove"]);
    }
}
