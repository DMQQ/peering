//! An in-memory `DiskOps` for tests. Paths are compared without regard to case, as Windows does.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, PoisonError};

use super::disk::{DiskError, DiskOps, Existing};

enum Node {
    Folder,
    File(Vec<u8>),
}

#[derive(Default)]
pub struct FakeDisk {
    nodes: BTreeMap<String, Node>,
    recycled: Vec<String>,
    protected: Vec<String>,
    remembered: Vec<String>,
    append_failure: Option<String>,
    commit_failure: Option<String>,
}

fn key(path: &str) -> String {
    path.trim_end_matches('\\').to_lowercase()
}

fn parent_of(key: &str) -> Option<&str> {
    key.rsplit_once('\\').map(|(parent, _)| parent)
}

impl FakeDisk {
    pub fn add_folder(&mut self, path: &str) {
        self.nodes.insert(key(path), Node::Folder);
    }

    pub fn add_file(&mut self, path: &str, bytes: &[u8]) {
        self.nodes.insert(key(path), Node::File(bytes.to_vec()));
    }

    pub fn protect(&mut self, path: &str) {
        self.protected.push(path.to_owned());
    }

    pub fn fail_appends_with(&mut self, message: &str) {
        self.append_failure = Some(message.to_owned());
    }

    pub fn fail_commits_with(&mut self, message: &str) {
        self.commit_failure = Some(message.to_owned());
    }

    pub fn contents(&self, path: &str) -> Option<Vec<u8>> {
        match self.nodes.get(&key(path)) {
            Some(Node::File(bytes)) => Some(bytes.clone()),
            _ => None,
        }
    }

    pub fn is_folder(&self, path: &str) -> bool {
        matches!(self.nodes.get(&key(path)), Some(Node::Folder))
    }

    pub fn exists(&self, path: &str) -> bool {
        self.nodes.contains_key(&key(path))
    }

    /// Every scratch file still on the disk.
    pub fn staging_files(&self) -> Vec<String> {
        self.nodes.keys().filter(|path| path.ends_with(".part")).cloned().collect()
    }

    pub fn recycled(&self) -> &[String] {
        &self.recycled
    }

    pub fn remembered_folders(&self) -> &[String] {
        &self.remembered
    }
}

impl DiskOps for FakeDisk {
    fn existing(&self, path: &str) -> Result<Existing, DiskError> {
        Ok(match self.nodes.get(&key(path)) {
            None => Existing::Nothing,
            Some(Node::Folder) => Existing::Folder,
            Some(Node::File(_)) => Existing::File,
        })
    }

    fn create_staging(&mut self, path: &str) -> Result<(), DiskError> {
        if !matches!(parent_of(&key(path)).and_then(|parent| self.nodes.get(parent)), Some(Node::Folder)) {
            return Err(DiskError("That folder is no longer there.".to_owned()));
        }
        self.nodes.insert(key(path), Node::File(Vec::new()));
        Ok(())
    }

    fn append(&mut self, path: &str, bytes: &[u8]) -> Result<(), DiskError> {
        if let Some(message) = &self.append_failure {
            return Err(DiskError(message.clone()));
        }
        match self.nodes.get_mut(&key(path)) {
            Some(Node::File(contents)) => {
                contents.extend_from_slice(bytes);
                Ok(())
            }
            _ => Err(DiskError("The scratch file is gone.".to_owned())),
        }
    }

    fn commit(&mut self, staging: &str, target: &str) -> Result<u64, DiskError> {
        if let Some(message) = &self.commit_failure {
            return Err(DiskError(message.clone()));
        }
        let Some(Node::File(bytes)) = self.nodes.remove(&key(staging)) else {
            return Err(DiskError("The scratch file is gone.".to_owned()));
        };
        let size = bytes.len() as u64;
        self.nodes.insert(key(target), Node::File(bytes));
        Ok(size)
    }

    fn discard(&mut self, staging: &str) {
        self.nodes.remove(&key(staging));
    }

    fn make_folder(&mut self, path: &str) -> Result<(), DiskError> {
        if self.exists(path) {
            return Err(DiskError("Something with that name is already there.".to_owned()));
        }
        self.add_folder(path);
        Ok(())
    }

    fn make_file(&mut self, path: &str) -> Result<(), DiskError> {
        if self.exists(path) {
            return Err(DiskError("Something with that name is already there.".to_owned()));
        }
        self.add_file(path, b"");
        Ok(())
    }

    fn rename(&mut self, from: &str, to: &str) -> Result<(), DiskError> {
        let node = self.nodes.remove(&key(from)).ok_or_else(|| DiskError("That is no longer there.".to_owned()))?;
        let children: Vec<String> = self.nodes.keys().filter(|child| child.starts_with(&format!("{}\\", key(from)))).cloned().collect();
        for child in children {
            if let Some(moved) = self.nodes.remove(&child) {
                self.nodes.insert(child.replacen(&key(from), &key(to), 1), moved);
            }
        }
        self.nodes.insert(key(to), node);
        Ok(())
    }

    fn recycle(&mut self, path: &str) -> Result<(), DiskError> {
        let prefix = format!("{}\\", key(path));
        self.nodes.retain(|existing, _| existing != &key(path) && !existing.starts_with(&prefix));
        self.recycled.push(path.to_owned());
        Ok(())
    }

    fn count_inside(&self, path: &str) -> Option<usize> {
        let prefix = format!("{}\\", key(path));
        Some(1 + self.nodes.keys().filter(|existing| existing.starts_with(&prefix)).count())
    }

    fn protected(&self) -> Vec<String> {
        self.protected.clone()
    }

    fn remember_staging_folder(&mut self, folder: &str) {
        self.remembered.push(folder.to_owned());
    }
}

/// A `FakeDisk` the test keeps a hold of while the code under test owns another handle to it.
#[derive(Clone, Default)]
pub struct SharedFakeDisk(Arc<Mutex<FakeDisk>>);

impl SharedFakeDisk {
    /// Looks at or changes the disk.
    pub fn with<R>(&self, use_disk: impl FnOnce(&mut FakeDisk) -> R) -> R {
        use_disk(&mut self.0.lock().unwrap_or_else(PoisonError::into_inner))
    }
}

impl DiskOps for SharedFakeDisk {
    fn existing(&self, path: &str) -> Result<Existing, DiskError> {
        self.with(|disk| disk.existing(path))
    }

    fn create_staging(&mut self, path: &str) -> Result<(), DiskError> {
        self.with(|disk| disk.create_staging(path))
    }

    fn append(&mut self, path: &str, bytes: &[u8]) -> Result<(), DiskError> {
        self.with(|disk| disk.append(path, bytes))
    }

    fn commit(&mut self, staging: &str, target: &str) -> Result<u64, DiskError> {
        self.with(|disk| disk.commit(staging, target))
    }

    fn discard(&mut self, staging: &str) {
        self.with(|disk| disk.discard(staging));
    }

    fn make_folder(&mut self, path: &str) -> Result<(), DiskError> {
        self.with(|disk| disk.make_folder(path))
    }

    fn make_file(&mut self, path: &str) -> Result<(), DiskError> {
        self.with(|disk| disk.make_file(path))
    }

    fn rename(&mut self, from: &str, to: &str) -> Result<(), DiskError> {
        self.with(|disk| disk.rename(from, to))
    }

    fn recycle(&mut self, path: &str) -> Result<(), DiskError> {
        self.with(|disk| disk.recycle(path))
    }

    fn count_inside(&self, path: &str) -> Option<usize> {
        self.with(|disk| disk.count_inside(path))
    }

    fn protected(&self) -> Vec<String> {
        self.with(|disk| disk.protected())
    }

    fn remember_staging_folder(&mut self, folder: &str) {
        self.with(|disk| disk.remember_staging_folder(folder));
    }
}
