//! WASAPI loopback capture on a thread of its own. Unverified: written against the `windows` 0.58 API and not run on Windows.
//!
//! The capture polls every 10 ms rather than waiting on an event, because an event driven loopback stream is not reliable on
//! every driver. WASAPI delivers no packets at all while nothing plays, which the host's pump reads as silence.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use peering_core::ports::audio::{AudioSource, CapturedAudio};
use windows::core::PWSTR;
use windows::Win32::Media::Audio::{
    eConsole, eRender, IAudioCaptureClient, IAudioClient, IMMDeviceEnumerator, MMDeviceEnumerator, AUDCLNT_BUFFERFLAGS_SILENT,
    AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, WAVEFORMATEX, WAVEFORMATEXTENSIBLE,
};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED};

use super::{decode_samples, retry_delay_seconds, sample_format, PacketQueue, SampleFormat};

const POLL: Duration = Duration::from_millis(10);
/// Loopback buffer length in 100 ns units: 200 ms, more than the polling ever lets fill.
const BUFFER_DURATION: i64 = 2_000_000;
/// How often the default playback device is checked, in polls.
const DEVICE_CHECK_POLLS: u32 = 100;

#[derive(Default)]
struct Shared {
    queue: Mutex<PacketQueue>,
    failure: Mutex<Option<String>>,
    stop: AtomicBool,
}

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The AudioSource of a Windows host. `set_active(true)` starts a capture thread; a thread that ended in failure is replaced
/// after a growing wait for as long as the source is wanted.
#[derive(Default)]
pub struct LoopbackAudio {
    shared: Arc<Shared>,
    worker: Option<JoinHandle<Result<(), String>>>,
    wanted: bool,
    failures: u32,
    retry_at: Option<Instant>,
}

impl LoopbackAudio {
    fn start(&mut self) {
        self.shared.stop.store(false, Ordering::Release);
        let shared = self.shared.clone();
        self.worker = Some(thread::spawn(move || capture(&shared)));
    }

    fn stop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            // The thread notices the flag within one poll; its result no longer matters.
            let _ended = worker.join();
        }
        locked(&self.shared.queue).clear();
        *locked(&self.shared.failure) = None;
        self.failures = 0;
        self.retry_at = None;
    }

    /// Replaces a capture that ended: at once after a device change, after a wait after a failure.
    fn supervise(&mut self) {
        if !self.worker.as_ref().is_some_and(JoinHandle::is_finished) {
            return;
        }
        let ended = self.worker.take().map(JoinHandle::join);
        match ended {
            Some(Ok(Ok(()))) => {
                self.failures = 0;
                *locked(&self.shared.failure) = None;
                self.start();
            }
            Some(Ok(Err(reason))) => {
                self.failures += 1;
                self.retry_at = Some(Instant::now() + Duration::from_secs_f64(retry_delay_seconds(self.failures)));
                *locked(&self.shared.failure) = Some(reason);
            }
            Some(Err(_panic)) => {
                self.failures += 1;
                self.retry_at = Some(Instant::now() + Duration::from_secs_f64(retry_delay_seconds(self.failures)));
                *locked(&self.shared.failure) = Some("the audio capture thread panicked".to_owned());
            }
            None => {}
        }
    }
}

impl AudioSource for LoopbackAudio {
    fn set_active(&mut self, active: bool) {
        if active == self.wanted {
            return;
        }
        self.wanted = active;
        if active {
            self.start();
        } else {
            self.stop();
        }
    }

    fn drain(&mut self) -> Vec<CapturedAudio> {
        if !self.wanted {
            return Vec::new();
        }
        self.supervise();
        if self.worker.is_none() && self.retry_at.is_some_and(|at| Instant::now() >= at) {
            self.retry_at = None;
            self.start();
        }
        locked(&self.shared.queue).take_all()
    }

    fn failure(&self) -> Option<String> {
        locked(&self.shared.failure).clone()
    }
}

impl Drop for LoopbackAudio {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Releases COM on the thread that initialised it.
struct ComGuard(bool);

impl ComGuard {
    fn new() -> Self {
        // SAFETY: called once on this thread, and balanced by `CoUninitialize` in `Drop` when it succeeded. A thread that
        // already initialised COM in another mode gets an error, which only means COM is usable but is not ours to release.
        Self(unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok())
    }
}

impl Drop for ComGuard {
    fn drop(&mut self) {
        if self.0 {
            // SAFETY: balances the successful `CoInitializeEx` of `new` on this same thread.
            unsafe { CoUninitialize() };
        }
    }
}

struct MixFormat {
    rate: u32,
    channels: u32,
    sample: SampleFormat,
}

/// Reads the mix format the device reports. `None` when its samples are not a layout the host reads.
fn describe(format: *mut WAVEFORMATEX) -> Option<MixFormat> {
    // SAFETY: GetMixFormat returned `format`, a valid WAVEFORMATEX (or the larger WAVEFORMATEXTENSIBLE its tag announces).
    // The extensible fields are packed, so they are read unaligned.
    unsafe {
        let base = format.read_unaligned();
        let extensible_tag = if u32::from(base.wFormatTag) == 0xFFFE {
            let extensible = format.cast::<WAVEFORMATEXTENSIBLE>();
            Some(std::ptr::addr_of!((*extensible).SubFormat).read_unaligned().data1)
        } else {
            None
        };
        sample_format(u32::from(base.wFormatTag), u32::from(base.wBitsPerSample), extensible_tag)
            .map(|sample| MixFormat { rate: base.nSamplesPerSec, channels: u32::from(base.nChannels), sample })
    }
}

fn default_device_id(enumerator: &IMMDeviceEnumerator) -> Result<String, String> {
    // SAFETY: plain COM calls on a live enumerator. The id string is copied out and then freed with CoTaskMemFree.
    unsafe {
        let device = enumerator.GetDefaultAudioEndpoint(eRender, eConsole).map_err(|error| format!("no playback device: {error}"))?;
        let id: PWSTR = device.GetId().map_err(|error| error.to_string())?;
        let text = id.to_string().map_err(|error| error.to_string());
        CoTaskMemFree(Some(id.0.cast_const().cast()));
        text
    }
}

/// Captures until told to stop. `Ok` also means the default playback device changed and a new capture should follow.
fn capture(shared: &Shared) -> Result<(), String> {
    let _com = ComGuard::new();
    // SAFETY: COM was initialised for this thread above; every interface used below is owned by this function.
    unsafe {
        let enumerator: IMMDeviceEnumerator =
            CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).map_err(|error| format!("audio devices: {error}"))?;
        let started_on = default_device_id(&enumerator)?;
        let device = enumerator.GetDefaultAudioEndpoint(eRender, eConsole).map_err(|error| format!("no playback device: {error}"))?;
        let client: IAudioClient = device.Activate(CLSCTX_ALL, None).map_err(|error| format!("audio client: {error}"))?;
        let raw_format = client.GetMixFormat().map_err(|error| format!("mix format: {error}"))?;
        let described = describe(raw_format);
        let opened = match described {
            Some(_) => client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, BUFFER_DURATION, 0, raw_format, None),
            None => Ok(()),
        };
        CoTaskMemFree(Some(raw_format.cast_const().cast()));
        let format = described.ok_or_else(|| "the playback device mixes in a sample format the host cannot read".to_owned())?;
        opened.map_err(|error| format!("loopback capture: {error}"))?;
        let packets: IAudioCaptureClient = client.GetService().map_err(|error| format!("capture service: {error}"))?;
        client.Start().map_err(|error| format!("starting the capture: {error}"))?;
        let outcome = read_until_stopped(shared, &enumerator, &started_on, &packets, &format);
        let _stopped = client.Stop();
        outcome
    }
}

/// # Safety
/// `packets` must belong to a started loopback client.
unsafe fn read_until_stopped(
    shared: &Shared,
    enumerator: &IMMDeviceEnumerator,
    started_on: &str,
    packets: &IAudioCaptureClient,
    format: &MixFormat,
) -> Result<(), String> {
    let mut polls = 0u32;
    while !shared.stop.load(Ordering::Acquire) {
        thread::sleep(POLL);
        polls += 1;
        if polls % DEVICE_CHECK_POLLS == 0 && default_device_id(enumerator).is_ok_and(|now| now != started_on) {
            return Ok(());
        }
        loop {
            let waiting = packets.GetNextPacketSize().map_err(|error| format!("reading the capture: {error}"))?;
            if waiting == 0 {
                break;
            }
            take_packet(shared, packets, format)?;
        }
    }
    Ok(())
}

/// # Safety
/// `packets` must belong to a started loopback client with a packet waiting.
unsafe fn take_packet(shared: &Shared, packets: &IAudioCaptureClient, format: &MixFormat) -> Result<(), String> {
    let mut data: *mut u8 = std::ptr::null_mut();
    let mut frames = 0u32;
    let mut flags = 0u32;
    packets.GetBuffer(&mut data, &mut frames, &mut flags, None, None).map_err(|error| format!("reading the capture: {error}"))?;
    let silent = flags & (AUDCLNT_BUFFERFLAGS_SILENT.0 as u32) != 0;
    if !silent && !data.is_null() && frames > 0 {
        let length = frames as usize * format.channels as usize * format.sample.bytes_per_sample();
        let bytes = std::slice::from_raw_parts(data, length);
        let samples = decode_samples(bytes, format.sample);
        locked(&shared.queue).push(CapturedAudio { sample_rate: format.rate, channels: format.channels, samples });
    }
    packets.ReleaseBuffer(frames).map_err(|error| format!("reading the capture: {error}"))
}
