//! Locates the shared protocol vectors so tests in every module read the same files.

use std::path::PathBuf;

pub fn vectors_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../docs/protocol/vectors").join(name)
}

#[cfg(test)]
pub fn load(name: &str) -> serde_json::Value {
    let text = std::fs::read_to_string(vectors_path(name)).expect("vector file is checked in");
    serde_json::from_str(&text).expect("vector file is valid JSON")
}

#[cfg(test)]
mod tests {
    #[test]
    fn crypto_vectors_are_readable() {
        assert_eq!(super::load("crypto.json")["sas"]["code"], "365357");
    }
}
