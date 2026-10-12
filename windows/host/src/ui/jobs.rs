//! Work the window must not wait for: `reg` and `netsh` can take seconds, and the window's thread also draws the tray. A job
//! runs on its own thread and its result is collected by the next frame.

use std::io;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::thread;

pub struct Jobs<T: Send + 'static> {
    sender: Sender<T>,
    receiver: Receiver<T>,
}

impl<T: Send + 'static> Default for Jobs<T> {
    fn default() -> Self {
        let (sender, receiver) = channel();
        Self { sender, receiver }
    }
}

impl<T: Send + 'static> Jobs<T> {
    /// Starts `work` on a new thread. Fails only when the thread cannot be created, and then `work` never ran.
    pub fn spawn(&self, name: &str, work: impl FnOnce() -> T + Send + 'static) -> io::Result<()> {
        let sender = self.sender.clone();
        thread::Builder::new().name(name.to_owned()).spawn(move || {
            // The receiver is gone only when the window has closed, and then nobody wants the result.
            let _undelivered = sender.send(work());
        })?;
        Ok(())
    }

    /// The results that have arrived since the last call.
    pub fn collect(&self) -> Vec<T> {
        std::iter::from_fn(|| self.receiver.try_recv().ok()).collect()
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;

    fn wait_for(jobs: &Jobs<u32>, count: usize) -> Vec<u32> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut results = Vec::new();
        while results.len() < count && Instant::now() < deadline {
            results.extend(jobs.collect());
            thread::sleep(Duration::from_millis(5));
        }
        results.sort_unstable();
        results
    }

    #[test]
    fn a_job_result_arrives_on_a_later_collect_without_blocking_the_caller() {
        let jobs = Jobs::default();
        let (release, held) = channel::<()>();
        jobs.spawn("slow", move || {
            held.recv().expect("released");
            7
        })
        .expect("a thread starts");
        assert!(jobs.collect().is_empty(), "the job is still running");
        release.send(()).expect("the job is waiting");
        assert_eq!(wait_for(&jobs, 1), [7]);
    }

    #[test]
    fn several_jobs_each_deliver_once() {
        let jobs = Jobs::default();
        for value in 1..=3 {
            jobs.spawn("job", move || value).expect("a thread starts");
        }
        assert_eq!(wait_for(&jobs, 3), [1, 2, 3]);
        assert!(jobs.collect().is_empty());
    }
}
