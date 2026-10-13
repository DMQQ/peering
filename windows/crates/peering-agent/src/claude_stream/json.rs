//! Reading fields out of one parsed line. Every lookup is lenient: a missing or mistyped field reads as absent.

use serde_json::{Map, Value};

pub type Object = Map<String, Value>;

pub fn str_field(object: &Object, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

pub fn int_field(object: &Object, key: &str) -> i64 {
    object.get(key).and_then(Value::as_i64).unwrap_or(0)
}

/// Every element must be an object, or the whole array reads as absent.
pub fn object_array(value: Option<&Value>) -> Option<Vec<&Object>> {
    value?.as_array()?.iter().map(Value::as_object).collect()
}
