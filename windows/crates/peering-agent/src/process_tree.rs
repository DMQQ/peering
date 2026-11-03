//! A child process together with everything it starts. On Windows a launcher (Git's `cmd\git.exe`, an npm shim)
//! hands the work to a grandchild that inherits the pipes, so killing the child alone leaves the pipes open.

use std::process::Child;

pub struct ProcessTree {
    #[cfg(windows)]
    job: Option<peering_platform::job::Job>,
}

impl ProcessTree {
    /// Without a job (Windows refused one, or another OS) only the child itself is ended.
    pub fn containing(child: &Child) -> Self {
        #[cfg(windows)]
        {
            use std::os::windows::io::AsRawHandle;
            Self { job: peering_platform::job::Job::containing(child.as_raw_handle()) }
        }
        #[cfg(not(windows))]
        {
            let _ = child;
            Self {}
        }
    }

    /// Ends the tree and reaps the child.
    pub fn stop(&self, child: &mut Child) {
        #[cfg(windows)]
        if let Some(job) = &self.job {
            job.terminate();
        }
        // Killing a child that has just exited fails harmlessly; the wait reaps it either way.
        let _killed = child.kill();
        let _reaped = child.wait();
    }
}
