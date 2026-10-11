//! An in-memory `FileSystem` for tests. Paths are Windows paths; `C:` and `C:\` name the same drive root.

use std::collections::{BTreeMap, BTreeSet};

use super::vfs::{FileSystem, FsError, RawEntry};

enum Node {
    Folder { modified: f64 },
    File { bytes: Vec<u8>, modified: f64 },
}

#[derive(Default)]
pub struct InMemoryFileSystem {
    /// Keyed by path without a trailing backslash, so a drive root is `C:`.
    nodes: BTreeMap<String, Node>,
    denied: BTreeSet<String>,
}

impl InMemoryFileSystem {
    /// Adds a folder and any folders above it that are not there yet.
    pub fn add_folder(&mut self, path: &str, modified: f64) {
        let key = normalize(path);
        let mut current = key.as_str();
        loop {
            self.nodes.entry(current.to_owned()).or_insert(Node::Folder { modified });
            match current.rsplit_once('\\') {
                Some((parent, _)) => current = parent,
                None => break,
            }
        }
    }

    pub fn add_file(&mut self, path: &str, bytes: &[u8], modified: f64) {
        let key = normalize(path);
        if let Some((parent, _)) = key.rsplit_once('\\') {
            self.add_folder(parent, modified);
        }
        self.nodes.insert(key, Node::File { bytes: bytes.to_vec(), modified });
    }

    /// Every operation on this path, or below it, fails with `AccessDenied`.
    pub fn deny(&mut self, path: &str) {
        self.denied.insert(normalize(path));
    }

    fn check(&self, key: &str) -> Result<&Node, FsError> {
        let denied = self.denied.iter().any(|prefix| key == prefix || key.starts_with(&format!("{prefix}\\")));
        if denied {
            return Err(FsError::AccessDenied);
        }
        self.nodes.get(key).ok_or(FsError::NotFound)
    }
}

impl FileSystem for InMemoryFileSystem {
    fn list(&self, path: &str) -> Result<Vec<RawEntry>, FsError> {
        let key = normalize(path);
        match self.check(&key)? {
            Node::File { .. } => Err(FsError::NotADirectory),
            Node::Folder { .. } => Ok(self
                .nodes
                .iter()
                .filter(|(child, _)| child.rsplit_once('\\').is_some_and(|(parent, _)| parent == key))
                .map(|(child, node)| entry(child, node))
                .collect()),
        }
    }

    fn read(&self, path: &str, offset: u64, limit: usize) -> Result<Vec<u8>, FsError> {
        match self.check(&normalize(path))? {
            Node::Folder { .. } => Err(FsError::NotAFile),
            Node::File { bytes, .. } => {
                let start = usize::try_from(offset).unwrap_or(usize::MAX).min(bytes.len());
                let end = start.saturating_add(limit).min(bytes.len());
                Ok(bytes[start..end].to_vec())
            }
        }
    }

    fn stat(&self, path: &str) -> Result<RawEntry, FsError> {
        let key = normalize(path);
        Ok(entry(&key, self.check(&key)?))
    }

    fn roots(&self) -> Vec<String> {
        self.nodes
            .iter()
            .filter(|(key, node)| !key.contains('\\') && matches!(node, Node::Folder { .. }))
            .map(|(key, _)| key.clone())
            .collect()
    }
}

fn normalize(path: &str) -> String {
    path.trim_end_matches('\\').to_owned()
}

fn entry(key: &str, node: &Node) -> RawEntry {
    let name = key.rsplit('\\').next().unwrap_or(key).to_owned();
    match node {
        Node::Folder { modified } => RawEntry {
            name,
            is_directory: true,
            is_symlink: false,
            size: 0,
            modified: Some(*modified),
        },
        Node::File { bytes, modified } => RawEntry {
            name,
            is_directory: false,
            is_symlink: false,
            size: i64::try_from(bytes.len()).unwrap_or(i64::MAX),
            modified: Some(*modified),
        },
    }
}
