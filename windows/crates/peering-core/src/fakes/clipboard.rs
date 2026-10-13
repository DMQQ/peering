//! A clipboard held in memory.

use std::sync::{Mutex, PoisonError};

use crate::ports::clipboard::{Clipboard, ClipboardContent, ClipboardError};

#[derive(Default)]
pub struct MemoryClipboard {
    content: Mutex<Option<ClipboardContent>>,
    failure: Mutex<Option<ClipboardError>>,
}

impl MemoryClipboard {
    pub fn holding(content: ClipboardContent) -> Self {
        Self { content: Mutex::new(Some(content)), failure: Mutex::new(None) }
    }

    /// Makes every later read and write fail with `error`.
    pub fn fail_with(&self, error: ClipboardError) {
        *self.failure.lock().unwrap_or_else(PoisonError::into_inner) = Some(error);
    }

    pub fn current(&self) -> Option<ClipboardContent> {
        self.content.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn failed(&self) -> Option<ClipboardError> {
        self.failure.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

impl Clipboard for MemoryClipboard {
    fn read(&self, allow_image: bool) -> Result<ClipboardContent, ClipboardError> {
        if let Some(error) = self.failed() {
            return Err(error);
        }
        Ok(match self.current() {
            Some(ClipboardContent::Image(_)) if !allow_image => ClipboardContent::Empty,
            Some(content) => content,
            None => ClipboardContent::Empty,
        })
    }

    fn write(&self, content: &ClipboardContent) -> Result<(), ClipboardError> {
        if let Some(error) = self.failed() {
            return Err(error);
        }
        if *content != ClipboardContent::Empty {
            *self.content.lock().unwrap_or_else(PoisonError::into_inner) = Some(content.clone());
        }
        Ok(())
    }
}
