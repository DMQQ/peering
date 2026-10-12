//! Captured textures travel from capture through NV12 conversion to encoder staging in one `Pipeline`. The handle type
//! `T` is the platform texture; the state machine is pure, so its rules are tested on any OS with a stand-in handle.
//!
//! A capture is converted at once, because the desktop duplication frame it came from is released by the next poll.
//! The converted frame waits in a single slot for the encoder. A slot that is replaced before the encoder takes it is a
//! dropped frame, and only the newest frame is ever encoded.

/// One frame's texture with the metadata the encoder needs. `sequence` orders frames; `width` and `height` are the
/// texture's size.
#[derive(Debug)]
pub struct FrameHandoff<T> {
    pub sequence: u64,
    pub width: u32,
    pub height: u32,
    pub texture: T,
}

/// The converted frame the encoder takes next. `force_keyframe` is set when a keyframe was requested since the last
/// take.
#[derive(Debug)]
pub struct EncodeRequest<T> {
    pub frame: FrameHandoff<T>,
    pub force_keyframe: bool,
}

#[derive(Debug)]
pub struct Pipeline<T> {
    staged: Option<FrameHandoff<T>>,
    keyframe_requested: bool,
    dropped_frames: u64,
}

impl<T> Default for Pipeline<T> {
    fn default() -> Self {
        Self { staged: None, keyframe_requested: false, dropped_frames: 0 }
    }
}

impl<T> Pipeline<T> {
    /// Converts a captured frame with `convert` and stages the result in place of any frame not yet encoded, which is
    /// counted as dropped. A failed conversion drops the capture and leaves the staged frame as it was.
    pub fn accept_capture<E>(
        &mut self,
        captured: FrameHandoff<T>,
        convert: impl FnOnce(FrameHandoff<T>) -> Result<FrameHandoff<T>, E>,
    ) -> Result<(), E> {
        match convert(captured) {
            Ok(converted) => {
                if self.staged.replace(converted).is_some() {
                    self.dropped_frames += 1;
                }
                Ok(())
            }
            Err(error) => {
                self.dropped_frames += 1;
                Err(error)
            }
        }
    }

    /// The next keyframe applies to the next frame the encoder takes, so a request made while nothing is staged waits.
    pub fn request_keyframe(&mut self) {
        self.keyframe_requested = true;
    }

    /// Hands the staged frame to the encoder. Returns None, and keeps any keyframe request, when nothing is staged.
    pub fn take_encode(&mut self) -> Option<EncodeRequest<T>> {
        let frame = self.staged.take()?;
        let force_keyframe = std::mem::take(&mut self.keyframe_requested);
        Some(EncodeRequest { frame, force_keyframe })
    }

    pub fn dropped_frames(&self) -> u64 {
        self.dropped_frames
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn captured(sequence: u64) -> FrameHandoff<u64> {
        FrameHandoff { sequence, width: 1920, height: 1080, texture: sequence * 10 }
    }

    /// Converts by moving the handle to a new id, as the NV12 step does by writing a new texture.
    fn convert_ok(input: FrameHandoff<u64>) -> Result<FrameHandoff<u64>, &'static str> {
        Ok(FrameHandoff {
            sequence: input.sequence,
            width: input.width,
            height: input.height,
            texture: input.texture + 1,
        })
    }

    #[test]
    fn a_captured_frame_is_converted_and_taken_once_for_the_encoder() {
        let mut pipeline = Pipeline::default();
        pipeline.accept_capture(captured(1), convert_ok).expect("converts");
        let request = pipeline.take_encode().expect("a frame is staged");
        assert_eq!(request.frame.sequence, 1);
        assert_eq!(request.frame.texture, 11);
        assert!(!request.force_keyframe);
        assert!(pipeline.take_encode().is_none());
        assert_eq!(pipeline.dropped_frames(), 0);
    }

    #[test]
    fn nothing_is_staged_before_the_first_capture() {
        let mut pipeline: Pipeline<u64> = Pipeline::default();
        assert!(pipeline.take_encode().is_none());
    }

    #[test]
    fn a_frame_replaced_before_the_encoder_takes_it_is_dropped_and_counted() {
        let mut pipeline = Pipeline::default();
        pipeline.accept_capture(captured(1), convert_ok).expect("converts");
        pipeline.accept_capture(captured(2), convert_ok).expect("converts");
        pipeline.accept_capture(captured(3), convert_ok).expect("converts");
        assert_eq!(pipeline.dropped_frames(), 2);
        let request = pipeline.take_encode().expect("the newest frame is staged");
        assert_eq!(request.frame.sequence, 3);
    }

    #[test]
    fn a_failed_conversion_drops_that_capture_and_keeps_the_staged_frame() {
        let mut pipeline = Pipeline::default();
        pipeline.accept_capture(captured(1), convert_ok).expect("converts");
        let failed = pipeline.accept_capture(captured(2), |_| Err("the video processor refused"));
        assert_eq!(failed, Err("the video processor refused"));
        assert_eq!(pipeline.dropped_frames(), 1);
        let request = pipeline.take_encode().expect("the earlier frame is still staged");
        assert_eq!(request.frame.sequence, 1);
    }

    #[test]
    fn a_keyframe_request_applies_to_the_next_frame_taken_and_only_once() {
        let mut pipeline = Pipeline::default();
        pipeline.accept_capture(captured(1), convert_ok).expect("converts");
        pipeline.request_keyframe();
        assert!(pipeline.take_encode().expect("staged").force_keyframe);
        pipeline.accept_capture(captured(2), convert_ok).expect("converts");
        assert!(!pipeline.take_encode().expect("staged").force_keyframe);
    }

    #[test]
    fn a_keyframe_requested_while_nothing_is_staged_waits_for_the_next_frame() {
        let mut pipeline = Pipeline::default();
        pipeline.request_keyframe();
        assert!(pipeline.take_encode().is_none());
        pipeline.accept_capture(captured(7), convert_ok).expect("converts");
        assert!(pipeline.take_encode().expect("staged").force_keyframe);
    }

    #[test]
    fn a_replaced_frame_does_not_consume_a_pending_keyframe_request() {
        let mut pipeline = Pipeline::default();
        pipeline.accept_capture(captured(1), convert_ok).expect("converts");
        pipeline.request_keyframe();
        pipeline.accept_capture(captured(2), convert_ok).expect("converts");
        assert!(pipeline.take_encode().expect("staged").force_keyframe);
        assert_eq!(pipeline.dropped_frames(), 1);
    }
}
