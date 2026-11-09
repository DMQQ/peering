//! MD5 as a corruption check on file transfers, as `FileChecksum.swift` is on the Mac: the channel is already authenticated
//! and encrypted, so this only catches a file that was written or read wrongly. Lowercase hex, fed in pieces.

const SHIFTS: [u32; 64] = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16,
    23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

pub struct FileChecksum {
    state: [u32; 4],
    block: [u8; 64],
    filled: usize,
    length: u64,
}

impl Default for FileChecksum {
    fn default() -> Self {
        Self { state: [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476], block: [0; 64], filled: 0, length: 0 }
    }
}

impl FileChecksum {
    pub fn update(&mut self, mut bytes: &[u8]) {
        self.length = self.length.wrapping_add(bytes.len() as u64);
        while !bytes.is_empty() {
            let take = (64 - self.filled).min(bytes.len());
            self.block[self.filled..self.filled + take].copy_from_slice(&bytes[..take]);
            self.filled += take;
            bytes = &bytes[take..];
            if self.filled == 64 {
                let block = self.block;
                self.compress(&block);
                self.filled = 0;
            }
        }
    }

    pub fn finalized(mut self) -> String {
        let bits = self.length.wrapping_mul(8);
        let padding = if self.filled < 56 { 56 - self.filled } else { 120 - self.filled };
        let mut tail = vec![0u8; padding];
        tail[0] = 0x80;
        tail.extend_from_slice(&bits.to_le_bytes());
        self.update(&tail);
        self.state.iter().flat_map(|word| word.to_le_bytes()).map(|byte| format!("{byte:02x}")).collect()
    }

    pub fn of(bytes: &[u8]) -> String {
        let mut checksum = Self::default();
        checksum.update(bytes);
        checksum.finalized()
    }

    fn compress(&mut self, block: &[u8; 64]) {
        let words: Vec<u32> = block.chunks_exact(4).map(|word| u32::from_le_bytes([word[0], word[1], word[2], word[3]])).collect();
        let [mut a, mut b, mut c, mut d] = self.state;
        for step in 0..64 {
            let (mixed, index) = match step / 16 {
                0 => ((b & c) | (!b & d), step),
                1 => ((d & b) | (!d & c), (5 * step + 1) % 16),
                2 => (b ^ c ^ d, (3 * step + 5) % 16),
                _ => (c ^ (b | !d), (7 * step) % 16),
            };
            let sum = a.wrapping_add(mixed).wrapping_add(constant(step)).wrapping_add(words[index]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(sum.rotate_left(SHIFTS[step]));
        }
        for (word, added) in self.state.iter_mut().zip([a, b, c, d]) {
            *word = word.wrapping_add(added);
        }
    }
}

/// The integer part of 2^32 times the absolute value of the sine of step + 1.
fn constant(step: usize) -> u32 {
    ((step as f64 + 1.0).sin().abs() * 4_294_967_296.0) as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_matches_the_rfc_1321_vectors() {
        assert_eq!(FileChecksum::of(b""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(FileChecksum::of(b"abc"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(FileChecksum::of(b"message digest"), "f96b697d7cb7938d525a2f31aaf161d0");
        assert_eq!(
            FileChecksum::of(b"12345678901234567890123456789012345678901234567890123456789012345678901234567890"),
            "57edf4a22be3c955ac49da2e2107b67a"
        );
    }

    #[test]
    fn pieces_of_any_size_give_the_same_hash_as_the_whole() {
        let data: Vec<u8> = (0..1000u32).map(|n| (n % 251) as u8).collect();
        let whole = FileChecksum::of(&data);
        for piece in [1, 7, 55, 56, 63, 64, 65, 300] {
            let mut checksum = FileChecksum::default();
            data.chunks(piece).for_each(|chunk| checksum.update(chunk));
            assert_eq!(checksum.finalized(), whole, "{piece}");
        }
    }
}
