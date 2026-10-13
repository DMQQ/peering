//! The shell call. Unverified: written against the `windows` 0.58 API and not run on Windows.

use std::sync::mpsc;
use std::time::Duration;

use windows::core::PCWSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::Storage::FileSystem::GetDriveTypeW;
use windows::Win32::UI::Shell::{
    SHFileOperationW, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, FOF_WANTNUKEWARNING, FO_DELETE, SHFILEOPSTRUCTW,
};

use peering_core::ports::recycle::Recycle;

use super::{bin_exists_for, drive_root, path_list};

/// Windows may stop to ask the person at the PC whether to delete for good, which nobody remote can answer. The call is given
/// this long, and the delete is reported as not done when it is still waiting.
const SHELL_DEADLINE: Duration = Duration::from_secs(30);

#[derive(Debug, Default, Clone, Copy)]
pub struct WindowsRecycleBin;

impl WindowsRecycleBin {
    fn move_to_bin(&self, path: &str) -> Result<(), String> {
        let root = drive_root(path).ok_or_else(|| "Only files on this PC's own drives can be moved to the Recycle Bin.".to_owned())?;
        if !bin_exists_for(drive_type(&root)) {
            return Err("That drive has no Recycle Bin, so Peering will not delete from it.".to_owned());
        }
        let list = path_list(path);
        let (sender, receiver) = mpsc::channel();
        // A call that waits for a dialog on the PC keeps its own thread until someone answers it.
        std::thread::spawn(move || {
            // The receiver is gone only when the deadline passed, and then nobody wants the answer.
            let _undelivered = sender.send(shell_delete(&list));
        });
        receiver.recv_timeout(SHELL_DEADLINE).unwrap_or_else(|_| Err("Windows is waiting for an answer on the PC, so nothing was deleted yet.".to_owned()))
    }
}

impl Recycle for WindowsRecycleBin {
    fn recycle(&self, path: &str) -> Result<(), String> {
        self.move_to_bin(path)
    }
}

fn drive_type(root: &str) -> u32 {
    let wide: Vec<u16> = root.encode_utf16().chain(std::iter::once(0)).collect();
    // SAFETY: `wide` is a zero terminated string that lives for the call.
    unsafe { GetDriveTypeW(PCWSTR(wide.as_ptr())) }
}

fn shell_delete(list: &[u16]) -> Result<(), String> {
    let flags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT | FOF_WANTNUKEWARNING;
    let mut operation = SHFILEOPSTRUCTW {
        hwnd: HWND::default(),
        wFunc: FO_DELETE,
        pFrom: PCWSTR(list.as_ptr()),
        pTo: PCWSTR::null(),
        fFlags: flags.0 as u16,
        ..Default::default()
    };
    // SAFETY: `operation` points at `list`, a zero zero terminated path list that outlives the call, and no other pointer in it is set.
    let status = unsafe { SHFileOperationW(&mut operation) };
    if status != 0 {
        return Err(format!("Windows could not move that to the Recycle Bin (error {status:#x})."));
    }
    if operation.fAnyOperationsAborted.as_bool() {
        return Err("Windows stopped before moving that to the Recycle Bin.".to_owned());
    }
    Ok(())
}
