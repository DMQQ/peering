//! One host per Windows session. A second launch asks the first to show its window and exits, because two hosts share one
//! port and two tray icons, and only one of them can be reached.

#[cfg(windows)]
mod sys {
    use windows::core::w;
    use windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS, HANDLE};
    use windows::Win32::System::Threading::{
        CreateEventW, CreateMutexW, OpenEventW, SetEvent, WaitForSingleObject, EVENT_MODIFY_STATE,
    };

    /// The mutex and the event are `Local\`, so each signed-in user has their own host.
    pub struct Guard {
        mutex: HANDLE,
        show: HANDLE,
    }

    // SAFETY: both handles are kernel objects that are valid on any thread, and `Guard` only waits on and closes them.
    unsafe impl Send for Guard {}

    pub enum Claim {
        First(Guard),
        /// Another host runs; it has been asked to show its window.
        Taken,
    }

    pub fn claim() -> Claim {
        // SAFETY: the names are static wide strings, and each handle is checked before use.
        unsafe {
            let Ok(mutex) = CreateMutexW(None, false, w!("Local\\PeeringHostSingleInstance")) else {
                // If the mutex cannot be made, running twice is better than not running.
                return Claim::First(Guard { mutex: HANDLE::default(), show: HANDLE::default() });
            };
            if GetLastError() == ERROR_ALREADY_EXISTS {
                let _closed = CloseHandle(mutex);
                if let Ok(show) = OpenEventW(EVENT_MODIFY_STATE, false, w!("Local\\PeeringHostShowWindow")) {
                    let _signalled = SetEvent(show);
                    let _closed = CloseHandle(show);
                }
                return Claim::Taken;
            }
            let show = CreateEventW(None, false, false, w!("Local\\PeeringHostShowWindow")).unwrap_or_default();
            Claim::First(Guard { mutex, show })
        }
    }

    impl Guard {
        /// True once for each launch that was turned away since the last call.
        pub fn take_show_request(&self) -> bool {
            if self.show.is_invalid() {
                return false;
            }
            // SAFETY: `show` is the event this guard created and still owns.
            unsafe { WaitForSingleObject(self.show, 0).0 == 0 }
        }
    }

    impl Drop for Guard {
        fn drop(&mut self) {
            // SAFETY: the handles are this guard's own and nothing uses them after it.
            unsafe {
                if !self.show.is_invalid() {
                    let _closed = CloseHandle(self.show);
                }
                if !self.mutex.is_invalid() {
                    let _closed = CloseHandle(self.mutex);
                }
            }
        }
    }
}

#[cfg(windows)]
pub use sys::{claim, Claim, Guard};
