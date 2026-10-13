//! Linear resampling of stereo Float32, carried across packets so a packet boundary adds no click.

/// Converts stereo at `from_rate` to stereo at `to_rate`, one packet at a time.
#[derive(Debug, Clone)]
pub struct StereoResampler {
    from_rate: u32,
    to_rate: u32,
    /// Position of the next output sample, counted in input frames from the start of `held`.
    position: f64,
    /// The last input frame of the previous packet, which the first interpolation of this one starts from.
    held: Option<[f32; 2]>,
}

impl StereoResampler {
    pub fn new(from_rate: u32, to_rate: u32) -> Self {
        Self { from_rate: from_rate.max(1), to_rate: to_rate.max(1), position: 0.0, held: None }
    }

    pub fn from_rate(&self) -> u32 {
        self.from_rate
    }

    /// `input` is interleaved stereo. The result is interleaved stereo at the output rate.
    pub fn process(&mut self, input: &[f32]) -> Vec<f32> {
        if self.from_rate == self.to_rate {
            return input.to_vec();
        }
        let frames = input.len() / 2;
        if frames == 0 {
            return Vec::new();
        }
        let step = f64::from(self.from_rate) / f64::from(self.to_rate);
        let frame_at = |index: isize| -> [f32; 2] {
            if index < 0 {
                self.held.unwrap_or([input[0], input[1]])
            } else {
                let at = (index as usize).min(frames - 1) * 2;
                [input[at], input[at + 1]]
            }
        };
        let mut out = Vec::with_capacity(((frames as f64 / step) as usize + 2) * 2);
        let mut position = self.position;
        // Output sample at `position` lies between input frames floor(position) - 1 (index -1 is the held frame) and floor(position).
        while position < frames as f64 {
            let whole = position.floor();
            let fraction = (position - whole) as f32;
            let before = frame_at(whole as isize - 1);
            let after = frame_at(whole as isize);
            out.push(before[0] + (after[0] - before[0]) * fraction);
            out.push(before[1] + (after[1] - before[1]) * fraction);
            position += step;
        }
        self.position = position - frames as f64;
        self.held = Some([input[frames * 2 - 2], input[frames * 2 - 1]]);
        out
    }

    pub fn reset(&mut self) {
        self.position = 0.0;
        self.held = None;
    }
}
