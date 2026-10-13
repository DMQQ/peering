//! What one phone has been sent of the audio stream. The clients restart their player on every `audioConfig`, so it is sent
//! once, and again only when the way to the phone changes (its video connection opened or closed), as the Mac does.

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct AudioDelivery {
    sent_via_video_connection: Option<bool>,
}

impl AudioDelivery {
    /// True when the config is owed before the next frame. `via_video_connection` says which route frames take now.
    pub fn config_due(&mut self, via_video_connection: bool) -> bool {
        if self.sent_via_video_connection == Some(via_video_connection) {
            return false;
        }
        self.sent_via_video_connection = Some(via_video_connection);
        true
    }

    /// The phone stopped listening, so the next sound starts with a config.
    pub fn pause(&mut self) {
        self.sent_via_video_connection = None;
    }
}
