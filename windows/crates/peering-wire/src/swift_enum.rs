//! Serde helpers for matching Swift `Codable` output. See docs/protocol.md section 7.
//!
//! Enums with payloads are modelled as serde struct variants: `Variant { field: T }` serialises to
//! `{"variant":{"field":..}}` as Swift does. An unlabelled Swift value is the field named `_0`
//! (`#[serde(rename = "_0")]`), and a Swift case without values is `Variant {}` giving `{"variant":{}}`.
//! Use `#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]` on the enum.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// `Data` as standard base64 with padding.
pub mod base64_bytes {
    use super::*;
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;

    pub fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        let text = String::deserialize(deserializer)?;
        STANDARD.decode(text).map_err(serde::de::Error::custom)
    }
}

/// `Optional<Data>`: absent when nil.
pub mod base64_bytes_option {
    use super::*;
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;

    pub fn serialize<S: Serializer>(bytes: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error> {
        match bytes {
            Some(bytes) => serializer.serialize_str(&STANDARD.encode(bytes)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error> {
        match Option::<String>::deserialize(deserializer)? {
            Some(text) => STANDARD.decode(text).map(Some).map_err(serde::de::Error::custom),
            None => Ok(None),
        }
    }
}

/// `[Data]`.
pub mod base64_list {
    use super::*;
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;

    pub fn serialize<S: Serializer>(list: &[Vec<u8>], serializer: S) -> Result<S::Ok, S::Error> {
        let texts: Vec<String> = list.iter().map(|b| STANDARD.encode(b)).collect();
        texts.serialize(serializer)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<Vec<u8>>, D::Error> {
        Vec::<String>::deserialize(deserializer)?
            .into_iter()
            .map(|t| STANDARD.decode(t).map_err(serde::de::Error::custom))
            .collect()
    }
}

/// Swift `Date` with the default strategy: seconds since 2001-01-01T00:00:00Z.
pub const REFERENCE_DATE_UNIX_OFFSET: f64 = 978_307_200.0;

pub fn unix_to_reference_date(unix_seconds: f64) -> f64 {
    unix_seconds - REFERENCE_DATE_UNIX_OFFSET
}

pub fn reference_date_to_unix(reference_seconds: f64) -> f64 {
    reference_seconds + REFERENCE_DATE_UNIX_OFFSET
}

/// `UUID` as uppercase hyphenated text.
pub fn uuid_text(uuid: &str) -> String {
    uuid.to_ascii_uppercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    #[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
    enum Sample {
        MouseMove { to: Point },
        SetVideoEnabled { #[serde(rename = "_0")] enabled: bool },
        LockScreen {},
    }

    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    struct Point {
        x: f64,
        y: f64,
    }

    #[derive(Debug, PartialEq, Serialize, Deserialize)]
    struct Blob {
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
        #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_bytes_option")]
        extra: Option<Vec<u8>>,
    }

    #[test]
    fn enum_cases_have_the_swift_shapes() {
        let move_json = serde_json::to_string(&Sample::MouseMove { to: Point { x: 0.5, y: 0.25 } }).unwrap();
        assert_eq!(move_json, r#"{"mouseMove":{"to":{"x":0.5,"y":0.25}}}"#);
        assert_eq!(serde_json::to_string(&Sample::SetVideoEnabled { enabled: false }).unwrap(), r#"{"setVideoEnabled":{"_0":false}}"#);
        assert_eq!(serde_json::to_string(&Sample::LockScreen {}).unwrap(), r#"{"lockScreen":{}}"#);
        assert_eq!(serde_json::from_str::<Sample>(r#"{"lockScreen":{}}"#).unwrap(), Sample::LockScreen {});
    }

    #[test]
    fn an_unknown_case_is_an_error_not_a_panic() {
        assert!(serde_json::from_str::<Sample>(r#"{"somethingNew":{}}"#).is_err());
    }

    #[test]
    fn data_is_padded_base64_and_nil_is_absent() {
        let blob = Blob { data: vec![1, 2], extra: None };
        let text = serde_json::to_string(&blob).unwrap();
        assert_eq!(text, r#"{"data":"AQI="}"#);
        assert_eq!(serde_json::from_str::<Blob>(&text).unwrap(), blob);
        assert_eq!(serde_json::from_str::<Blob>(r#"{"data":"AQI=","extra":null}"#).unwrap(), blob);
    }

    #[test]
    fn reference_dates_convert_both_ways() {
        assert_eq!(unix_to_reference_date(978_307_200.0), 0.0);
        assert_eq!(reference_date_to_unix(0.0), 978_307_200.0);
        assert_eq!(uuid_text("0a1b2c3d-0000-4000-8000-00000000000f"), "0A1B2C3D-0000-4000-8000-00000000000F");
    }
}
