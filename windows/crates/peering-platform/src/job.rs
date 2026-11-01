//! A job object that ends everything a shell started when the job is closed or the host dies.

use std::ffi::c_void;
use std::mem::size_of;
use std::os::windows::io::RawHandle;

use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};

pub(super) struct Job(HANDLE);

// SAFETY: a job object handle names a kernel object and may be used and closed from any thread.
unsafe impl Send for Job {}

impl Job {
    /// Puts the process in a new job that kills its members when the job closes. `None` when Windows refuses, in
    /// which case the shell still runs but its children can outlive it.
    pub(super) fn containing(process: RawHandle) -> Option<Self> {
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
}

impl Drop for Job {
    fn drop(&mut self) {
        // A handle that cannot be closed has nothing left to do; the job's members are ended by the close itself.
        // SAFETY: the handle is owned by this value and closed once.
        let _closed = unsafe { CloseHandle(self.0) };
    }
}
