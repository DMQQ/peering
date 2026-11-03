//! The event-driven way to run an encoder. A hardware encoder is an asynchronous MFT: it says through events when it can take
//! a frame (`METransformNeedInput`) and when a packet is ready (`METransformHaveOutput`), and fails any call made without one.

use super::io::{output_buffer, read_sample, renegotiate_output, take_sample, EncodedBytes};
use super::Session;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use windows::core::{Error as WinError, Result as WinResult};
use windows::Win32::Foundation::E_FAIL;
use windows::Win32::Media::MediaFoundation::{
    IMFMediaEventGenerator, IMFSample, MEError, METransformHaveOutput, METransformNeedInput, MF_E_NO_EVENTS_AVAILABLE,
    MF_E_TRANSFORM_NEED_MORE_INPUT, MF_E_TRANSFORM_STREAM_CHANGE, MF_EVENT_FLAG_NO_WAIT,
};

/// How long one frame may wait for the encoder to announce a free input slot or hand back its packet. Longer than any healthy
/// frame, so a stalled encoder surfaces as an error to the caller's own recovery rather than blocking the pipeline.
const WAIT: Duration = Duration::from_millis(250);
const POLL: Duration = Duration::from_millis(1);

/// Feeds `sample` once the encoder has room, and returns the packets it has ready. A low-latency encoder answers each frame with
/// one packet; an event for a packet that arrives later stays queued and is collected by the next call.
pub(super) fn submit_and_collect(
    session: &Session,
    events: &IMFMediaEventGenerator,
    sample: &IMFSample,
) -> WinResult<Vec<EncodedBytes>> {
    let mut outputs = Vec::new();
    let mut fed = false;
    let deadline = Instant::now() + WAIT;
    loop {
        if !fed && take_credit(session) {
            // SAFETY: the encoder announced room for this input, and the sample is live; ProcessInput takes its own reference.
            unsafe { session.transform.ProcessInput(0, sample, 0)? };
            fed = true;
        }
        match next_event(events)? {
            Some(Event::NeedInput) => {
                session.input_credits.fetch_add(1, Ordering::AcqRel);
            }
            Some(Event::HaveOutput) => collect_output(session, &mut outputs)?,
            None if fed && !outputs.is_empty() => return Ok(outputs),
            None if Instant::now() >= deadline => {
                return if fed {
                    Ok(outputs)
                } else {
                    Err(WinError::new(E_FAIL, "the encoder did not ask for another frame in time"))
                };
            }
            None => std::thread::sleep(POLL),
        }
    }
}

fn take_credit(session: &Session) -> bool {
    session
        .input_credits
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |credits| credits.checked_sub(1))
        .is_ok()
}

enum Event {
    NeedInput,
    HaveOutput,
}

/// The next event that matters, or `None` when the queue is empty. Other events (drain and marker notices) are skipped.
fn next_event(events: &IMFMediaEventGenerator) -> WinResult<Option<Event>> {
    loop {
        // SAFETY: the generator is live; with NO_WAIT the call returns at once, with an error when nothing is queued.
        let event = match unsafe { events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
            Ok(event) => event,
            Err(error) if error.code() == MF_E_NO_EVENTS_AVAILABLE => return Ok(None),
            Err(error) => return Err(error),
        };
        // SAFETY: the event is a live object we own.
        let kind = unsafe { event.GetType()? };
        if kind == METransformNeedInput.0 as u32 {
            return Ok(Some(Event::NeedInput));
        }
        if kind == METransformHaveOutput.0 as u32 {
            return Ok(Some(Event::HaveOutput));
        }
        if kind == MEError.0 as u32 {
            // SAFETY: as above; the status carries the encoder's own failure code.
            let status = unsafe { event.GetStatus()? };
            return Err(WinError::new(status, "the encoder reported an error"));
        }
    }
}

fn collect_output(session: &Session, outputs: &mut Vec<EncodedBytes>) -> WinResult<()> {
    loop {
        let mut buffers = [output_buffer(session)?];
        let mut status = 0u32;
        // SAFETY: one initialised output buffer is passed; on return the MFT has filled or left its sample.
        let result = unsafe { session.transform.ProcessOutput(0, &mut buffers, &mut status) };
        let [buffer] = buffers;
        let sample = take_sample(buffer);
        match result {
            Ok(()) => {
                if let Some(sample) = sample {
                    outputs.push(read_sample(&sample)?);
                }
                return Ok(());
            }
            Err(error) if error.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(()),
            // The new output type is accepted and the call repeated, as the synchronous path does.
            Err(error) if error.code() == MF_E_TRANSFORM_STREAM_CHANGE => renegotiate_output(session)?,
            Err(error) => return Err(error),
        }
    }
}
