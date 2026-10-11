//! Capture sources and the catalogue the host pushes. See docs/protocol.md section 8.

use crate::swift_enum::base64_bytes_option;
use serde::{Deserialize, Serialize};

/// What the host captures. Raw platform ids, so the wire does not depend on any OS header.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum CaptureSource {
    Display {
        #[serde(rename = "_0")]
        id: u32,
    },
    Application {
        #[serde(rename = "_0")]
        pid: i32,
    },
    Window {
        #[serde(rename = "_0")]
        id: u32,
    },
    Mosaic {
        #[serde(rename = "_0")]
        layout: serde_json::Value,
    },
}

impl CaptureSource {
    pub fn stable_id(&self) -> String {
        match self {
            Self::Display { id } => format!("display:{id}"),
            Self::Application { pid } => format!("application:{pid}"),
            Self::Window { id } => format!("window:{id}"),
            Self::Mosaic { .. } => "mosaic".to_string(),
        }
    }
}

/// A point in the captured source's own space: (0,0) top left, (1,1) bottom right.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct NormalizedPoint {
    pub x: f64,
    pub y: f64,
}

impl NormalizedPoint {
    pub fn clamped(self) -> Self {
        Self { x: unit_interval(self.x), y: unit_interval(self.y) }
    }
}

/// `clamp` passes NaN through, and a NaN cursor coordinate must not reach the host's cursor maths.
fn unit_interval(value: f64) -> f64 {
    if value.is_nan() {
        0.0
    } else {
        value.clamp(0.0, 1.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CaptureSourceKind {
    Display,
    Application,
    Window,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSourceDescriptor {
    pub id: String,
    pub kind: CaptureSourceKind,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_identifier: Option<String>,
    #[serde(
        default,
        rename = "iconPNGData",
        skip_serializing_if = "Option::is_none",
        with = "base64_bytes_option"
    )]
    pub icon_png_data: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumbnail: Option<serde_json::Value>,
    pub source: CaptureSource,
    /// Real pixels, not points.
    pub pixel_size: [f64; 2],
    #[serde(default)]
    pub is_managed_virtual_display: bool,
    #[serde(default)]
    pub is_virtual_display: bool,
}

impl CaptureSourceDescriptor {
    pub fn display(id: u32, title: &str, width: u32, height: u32) -> Self {
        let source = CaptureSource::Display { id };
        Self {
            id: source.stable_id(),
            kind: CaptureSourceKind::Display,
            title: title.to_string(),
            subtitle: None,
            bundle_identifier: None,
            icon_png_data: None,
            thumbnail: None,
            source,
            pixel_size: [f64::from(width), f64::from(height)],
            is_managed_virtual_display: false,
            is_virtual_display: false,
        }
    }
}

/// Every list may be absent on input. All four lists are always written, so an empty list is `[]`.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureCatalog {
    #[serde(default)]
    pub displays: Vec<CaptureSourceDescriptor>,
    #[serde(default)]
    pub applications: Vec<CaptureSourceDescriptor>,
    #[serde(default)]
    pub windows: Vec<CaptureSourceDescriptor>,
    #[serde(default)]
    pub installed_applications: Vec<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub space_info: Option<serde_json::Value>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vectors_dir::load;
    use serde_json::{json, Value};

    /// Numbers compared as f64: Swift writes `1920`, serde_json writes `1920.0` for the same pixel size.
    fn numbers_as_f64(value: &Value) -> Value {
        match value {
            Value::Number(number) => json!(number.as_f64()),
            Value::Array(items) => Value::Array(items.iter().map(numbers_as_f64).collect()),
            Value::Object(map) => Value::Object(map.iter().map(|(k, v)| (k.clone(), numbers_as_f64(v))).collect()),
            other => other.clone(),
        }
    }

    fn vector_json(name: &str) -> Value {
        let cases = load("messages.json");
        let case = cases["cases"].as_array().unwrap().iter().find(|c| c["name"] == name).unwrap();
        serde_json::from_str(case["json"].as_str().unwrap()).unwrap()
    }

    #[test]
    fn catalog_displays_only_round_trips() {
        let original = vector_json("catalog displays only");
        let catalog: CaptureCatalog = serde_json::from_value(original.clone()).unwrap();
        let written = serde_json::to_value(&catalog).unwrap();
        assert_eq!(numbers_as_f64(&written["displays"]), numbers_as_f64(&original["displays"]));
        assert_eq!(written["applications"], json!([]));
        assert_eq!(written["windows"], json!([]));
        assert_eq!(written["installedApplications"], json!([]));
        assert!(written.get("spaceInfo").is_none());
    }

    #[test]
    fn a_display_descriptor_writes_the_swift_keys() {
        let descriptor = CaptureSourceDescriptor::display(1, "Built-in", 1920, 1080);
        let written = serde_json::to_value(&descriptor).unwrap();
        assert_eq!(
            numbers_as_f64(&written),
            numbers_as_f64(&json!({
                "id": "display:1",
                "kind": "display",
                "title": "Built-in",
                "source": {"display": {"_0": 1}},
                "pixelSize": [1920, 1080],
                "isManagedVirtualDisplay": false,
                "isVirtualDisplay": false
            }))
        );
    }

    #[test]
    fn stable_ids_match_the_swift_names() {
        assert_eq!(CaptureSource::Display { id: 1 }.stable_id(), "display:1");
        assert_eq!(CaptureSource::Application { pid: 42 }.stable_id(), "application:42");
        assert_eq!(CaptureSource::Window { id: 7 }.stable_id(), "window:7");
        assert_eq!(CaptureSource::Mosaic { layout: json!({}) }.stable_id(), "mosaic");
    }

    #[test]
    fn capture_sources_use_the_underscore_zero_payload_key() {
        let text = serde_json::to_string(&CaptureSource::Application { pid: -3 }).unwrap();
        assert_eq!(text, r#"{"application":{"_0":-3}}"#);
        let parsed: CaptureSource = serde_json::from_str(r#"{"window":{"_0":7}}"#).unwrap();
        assert_eq!(parsed, CaptureSource::Window { id: 7 });
    }

    #[test]
    fn points_clamp_to_the_unit_square() {
        let clamped = NormalizedPoint { x: -0.5, y: 1.5 }.clamped();
        assert_eq!(clamped, NormalizedPoint { x: 0.0, y: 1.0 });
        let inside = NormalizedPoint { x: 0.25, y: 0.75 };
        assert_eq!(inside.clamped(), inside);
    }

    #[test]
    fn a_nan_point_clamps_to_the_origin() {
        let clamped = NormalizedPoint { x: f64::NAN, y: 0.5 }.clamped();
        assert_eq!(clamped, NormalizedPoint { x: 0.0, y: 0.5 });
    }

    #[test]
    fn a_descriptor_without_optional_fields_decodes() {
        let text = r#"{"id":"window:7","kind":"window","title":"Notes","source":{"window":{"_0":7}},"pixelSize":[800,600]}"#;
        let descriptor: CaptureSourceDescriptor = serde_json::from_str(text).unwrap();
        assert_eq!(descriptor.kind, CaptureSourceKind::Window);
        assert_eq!(descriptor.subtitle, None);
        assert_eq!(descriptor.icon_png_data, None);
        assert!(!descriptor.is_managed_virtual_display);
        assert!(!descriptor.is_virtual_display);
    }

    #[test]
    fn an_unknown_extra_key_is_ignored() {
        let text = r#"{"id":"display:1","kind":"display","title":"A","source":{"display":{"_0":1}},"pixelSize":[1,1],"futureField":{"anything":true}}"#;
        let descriptor: CaptureSourceDescriptor = serde_json::from_str(text).unwrap();
        assert_eq!(descriptor.source, CaptureSource::Display { id: 1 });
    }

    #[test]
    fn an_icon_is_base64_under_the_swift_key_spelling() {
        let mut descriptor = CaptureSourceDescriptor::display(1, "A", 1, 1);
        descriptor.icon_png_data = Some(vec![1, 2]);
        let written = serde_json::to_value(&descriptor).unwrap();
        assert_eq!(written["iconPNGData"], "AQI=");
    }

    #[test]
    fn a_catalog_with_no_lists_decodes_as_empty() {
        let catalog: CaptureCatalog = serde_json::from_str("{}").unwrap();
        assert_eq!(catalog, CaptureCatalog::default());
    }
}
