//! A job object that ends everything a process started (a shell, an npm shim's node, git's launcher) when the job is
//! terminated or closed, or the host dies.

use std::ffi::c_void;
use std::mem::size_of;
use std::os::windows::io::RawHandle;

use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, TerminateJobObject, JobObjectExtendedLimitInformation, SetInformationJobObject,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};

pub struct Job(HANDLE);

// SAFETY: a job object handle names a kernel object and may be used and closed from any thread.
unsafe impl Send for Job {}

impl Job {
    /// Puts the process in a new job that kills its members when the job closes. `None` when Windows refuses, in
    /// which case the process still runs but its children can outlive it.
    pub fn containing(process: RawHandle) -> Option<Self> {
        // SAFETY: the handle is created here and owned by `Job`, which closes it on every path out of this function.
        let job = Job(unsafe { CreateJobObjectW(None, None) }.ok()?);
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // SAFETY: `limits` is a live value of the structure the information class names, and `process` is the live
        // process handle its owner passed in.
        unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                std::ptr::addr_of!(limits).cast::<c_void>(),
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
            .ok()?;
            AssignProcessToJobObject(job.0, HANDLE(process)).ok()?;
        }
        Some(job)
    }

    /// Ends every process in the job now, which also closes the pipes they inherited.
    pub fn terminate(&self) {
        // A job whose members have all exited has nothing to end; failure here changes nothing.
        // SAFETY: the handle is owned by this value and still open.
        let _ended = unsafe { TerminateJobObject(self.0, 1) };
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        // A handle that cannot be closed has nothing left to do; the job's members are ended by the close itself.
        // SAFETY: the handle is owned by this value and closed once.
        let _closed = unsafe { CloseHandle(self.0) };
    }
}
