//! File-browser models: directory entries, file kinds and the operations that change a file.

use serde::{Deserialize, Serialize};

/// One entry of a folder listing. There is no path: it is the listing's path plus `name`.
///
/// `is_directory` is true for a symbolic link that points at a folder, because that is what a tap on the row asks;
/// `is_symlink` tells the two apart. `modified` is seconds since 2001-01-01, a Swift `Date`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteDirectoryEntry {
    pub name: String,
    pub is_directory: bool,
    pub is_symlink: bool,
    pub size: i64,
    pub permissions: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub modified: Option<f64>,
}

/// What a created entry is. Narrower than [`RemoteFileKind`], which says how a file is drawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteEntryKind {
    File,
    Folder,
}

/// How the client draws a file's contents.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteFileKind {
    Text,
    Image,
    Svg,
    Pdf,
    Video,
}

/// A change to one entry. `rename` takes a bare name, not a path, so it cannot move a file across folders.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum RemoteFileOperation {
    Create {
        path: String,
        kind: RemoteEntryKind,
    },
    Rename {
        path: String,
        to: String,
    },
    Delete {
        path: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn round_trip<T>(json: Value) -> Value
    where
        T: Serialize + serde::de::DeserializeOwned,
    {
        let decoded: T = serde_json::from_value(json).expect("the literal decodes");
        serde_json::to_value(&decoded).expect("the model encodes")
    }

    #[test]
    fn a_directory_entry_round_trips_with_its_modified_date() {
        let entry = json!({
            "name": "src", "isDirectory": true, "isSymlink": false,
            "size": 4096, "permissions": "drwxr-xr-x", "modified": 812979000.0
        });
        assert_eq!(round_trip::<RemoteDirectoryEntry>(entry.clone()), entry);
    }

    #[test]
    fn an_entry_without_a_modified_date_omits_the_key() {
        let entry = json!({
            "name": "link", "isDirectory": false, "isSymlink": true,
            "size": 0, "permissions": "lrwxr-xr-x"
        });
        let decoded: RemoteDirectoryEntry = serde_json::from_value(entry.clone()).expect("decodes");
        assert_eq!(decoded.modified, None);
        assert_eq!(serde_json::to_value(&decoded).expect("encodes"), entry);
    }

    #[test]
    fn entry_kinds_and_file_kinds_use_the_swift_raw_values() {
        assert_eq!(round_trip::<RemoteEntryKind>(json!("folder")), json!("folder"));
        assert_eq!(round_trip::<RemoteEntryKind>(json!("file")), json!("file"));
        for kind in ["text", "image", "svg", "pdf", "video"] {
            assert_eq!(round_trip::<RemoteFileKind>(json!(kind)), json!(kind));
        }
    }

    #[test]
    fn every_file_operation_round_trips() {
        let create = json!({"create": {"path": "/Users/me/new.txt", "kind": "file"}});
        let rename = json!({"rename": {"path": "/Users/me/a.txt", "to": "b.txt"}});
        let delete = json!({"delete": {"path": "/Users/me/old"}});
        assert_eq!(round_trip::<RemoteFileOperation>(create.clone()), create);
        assert_eq!(round_trip::<RemoteFileOperation>(rename.clone()), rename);
        assert_eq!(round_trip::<RemoteFileOperation>(delete.clone()), delete);
    }

    #[test]
    fn an_unknown_file_kind_is_an_error_not_a_panic() {
        assert!(serde_json::from_value::<RemoteFileKind>(json!("audio")).is_err());
        assert!(serde_json::from_value::<RemoteFileOperation>(json!({"move": {}})).is_err());
    }
}
