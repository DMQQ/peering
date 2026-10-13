//! The captured sound waiting for the host to take it. The capture thread fills it and the host's pump empties it, so a pump
//! that stalls loses the oldest sound instead of growing memory.

use std::collections::VecDeque;

use peering_core::ports::audio::CapturedAudio;

/// A second of 48 kHz stereo; past this the oldest packets are dropped.
const LIMIT_SAMPLES: usize = 48_000 * 2;

#[derive(Debug, Default)]
pub struct PacketQueue {
    packets: VecDeque<CapturedAudio>,
    samples: usize,
}

impl PacketQueue {
    pub fn push(&mut self, packet: CapturedAudio) {
        self.samples += packet.samples.len();
        self.packets.push_back(packet);
        while self.samples > LIMIT_SAMPLES && self.packets.len() > 1 {
            if let Some(oldest) = self.packets.pop_front() {
                self.samples -= oldest.samples.len();
            }
        }
    }

    pub fn take_all(&mut self) -> Vec<CapturedAudio> {
        self.samples = 0;
        self.packets.drain(..).collect()
    }

    pub fn clear(&mut self) {
        self.samples = 0;
        self.packets.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packet(tag: f32, samples: usize) -> CapturedAudio {
        CapturedAudio { sample_rate: 48_000, channels: 2, samples: vec![tag; samples] }
    }

    #[test]
    fn packets_come_out_oldest_first_and_the_queue_empties() {
        let mut queue = PacketQueue::default();
        queue.push(packet(1.0, 10));
        queue.push(packet(2.0, 10));
        let taken = queue.take_all();
        assert_eq!(taken.iter().map(|packet| packet.samples[0]).collect::<Vec<_>>(), vec![1.0, 2.0]);
        assert!(queue.take_all().is_empty());
    }

    #[test]
    fn a_stalled_reader_loses_the_oldest_sound_and_keeps_the_newest() {
        let mut queue = PacketQueue::default();
        for tag in 0..5 {
            queue.push(packet(tag as f32, LIMIT_SAMPLES / 2));
        }
        let taken = queue.take_all();
        assert_eq!(taken.len(), 2);
        assert_eq!(taken[1].samples[0], 4.0);
    }

    #[test]
    fn one_packet_larger_than_the_limit_is_kept() {
        let mut queue = PacketQueue::default();
        queue.push(packet(1.0, LIMIT_SAMPLES * 2));
        assert_eq!(queue.take_all().len(), 1);
    }

    #[test]
    fn clearing_forgets_everything() {
        let mut queue = PacketQueue::default();
        queue.push(packet(1.0, 10));
        queue.clear();
        assert!(queue.take_all().is_empty());
    }
}
