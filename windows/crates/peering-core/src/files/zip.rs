//! A streaming ZIP writer: each file is deflated as it is read and its size and checksum follow it in a data descriptor, so
//! nothing is held in memory or written twice. The archive is capped; a write that would pass the cap fails with `LimitExceeded`.

use std::io::{self, Read, Write};

use crate::calendar::civil_from_days;
use flate2::write::DeflateEncoder;
use flate2::Compression;

const LOCAL_HEADER: u32 = 0x0403_4b50;
const DATA_DESCRIPTOR: u32 = 0x0807_4b50;
const CENTRAL_HEADER: u32 = 0x0201_4b50;
const END_OF_DIRECTORY: u32 = 0x0605_4b50;
const VERSION: u16 = 20;
/// Bit 3: sizes follow the data. Bit 11: names are UTF-8.
const FLAGS_FILE: u16 = 0x0808;
const FLAGS_FOLDER: u16 = 0x0800;
const STORED: u16 = 0;
const DEFLATED: u16 = 8;
const FOLDER_ATTRIBUTE: u32 = 0x10;
const COPY_BUFFER: usize = 64 * 1024;

pub const MAXIMUM_ENTRIES: usize = u16::MAX as usize;

/// The reason a write failed when the archive grew past its cap.
#[derive(Debug)]
pub struct LimitExceeded;

impl std::fmt::Display for LimitExceeded {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("the archive is larger than allowed")
    }
}

impl std::error::Error for LimitExceeded {}

pub fn is_limit_exceeded(error: &io::Error) -> bool {
    error.get_ref().is_some_and(|inner| inner.is::<LimitExceeded>())
}

/// Counts what passes through and refuses what would pass `limit`.
struct Counting<W> {
    inner: W,
    written: u64,
    limit: u64,
}

impl<W: Write> Write for Counting<W> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if self.written + bytes.len() as u64 > self.limit {
            return Err(io::Error::other(LimitExceeded));
        }
        let count = self.inner.write(bytes)?;
        self.written += count as u64;
        Ok(count)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

struct Entry {
    name: String,
    folder: bool,
    time: u16,
    date: u16,
    crc: u32,
    compressed: u32,
    uncompressed: u32,
    offset: u32,
}

pub struct ZipWriter<W: Write> {
    out: Counting<W>,
    entries: Vec<Entry>,
}

impl<W: Write> ZipWriter<W> {
    pub fn new(out: W, limit: u64) -> Self {
        Self { out: Counting { inner: out, written: 0, limit }, entries: Vec::new() }
    }

    pub fn entries(&self) -> usize {
        self.entries.len()
    }

    /// Bytes written so far, which is the size of the archive once `finish` has added the directory.
    pub fn written(&self) -> u64 {
        self.out.written
    }

    /// `name` ends with a slash and uses slashes throughout.
    pub fn add_folder(&mut self, name: &str, time: (u16, u16)) -> io::Result<()> {
        let offset = self.offset()?;
        self.local_header(name, FLAGS_FOLDER, STORED, time)?;
        self.entries.push(Entry { name: name.to_owned(), folder: true, time: time.0, date: time.1, crc: 0, compressed: 0, uncompressed: 0, offset });
        Ok(())
    }

    /// Deflates everything `source` yields. A source that fails part way leaves the archive unusable, so the caller drops it.
    pub fn add_file(&mut self, name: &str, time: (u16, u16), source: &mut dyn Read) -> io::Result<()> {
        let offset = self.offset()?;
        self.local_header(name, FLAGS_FILE, DEFLATED, time)?;
        let start = self.out.written;
        let mut crc = crc32fast::Hasher::new();
        let mut uncompressed = 0u64;
        let mut encoder = DeflateEncoder::new(&mut self.out, Compression::fast());
        let mut buffer = vec![0u8; COPY_BUFFER];
        loop {
            let count = source.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            crc.update(&buffer[..count]);
            uncompressed += count as u64;
            encoder.write_all(&buffer[..count])?;
        }
        encoder.finish()?;
        let compressed = self.out.written - start;
        let (compressed, uncompressed) = (as_u32(compressed)?, as_u32(uncompressed)?);
        let crc = crc.finalize();
        let mut descriptor = Vec::with_capacity(16);
        descriptor.extend_from_slice(&DATA_DESCRIPTOR.to_le_bytes());
        descriptor.extend_from_slice(&crc.to_le_bytes());
        descriptor.extend_from_slice(&compressed.to_le_bytes());
        descriptor.extend_from_slice(&uncompressed.to_le_bytes());
        self.out.write_all(&descriptor)?;
        self.entries.push(Entry { name: name.to_owned(), folder: false, time: time.0, date: time.1, crc, compressed, uncompressed, offset });
        Ok(())
    }

    /// Writes the directory that makes the archive readable and returns what it was written to, with the archive's size.
    pub fn finish(mut self) -> io::Result<(W, u64)> {
        let directory_start = self.offset()?;
        let mut directory = Vec::new();
        for entry in &self.entries {
            directory.extend_from_slice(&central_record(entry));
        }
        self.out.write_all(&directory)?;
        let count = u16::try_from(self.entries.len()).map_err(|_| io::Error::other(LimitExceeded))?;
        let mut end = Vec::with_capacity(22);
        end.extend_from_slice(&END_OF_DIRECTORY.to_le_bytes());
        end.extend_from_slice(&[0; 4]);
        end.extend_from_slice(&count.to_le_bytes());
        end.extend_from_slice(&count.to_le_bytes());
        end.extend_from_slice(&as_u32(directory.len() as u64)?.to_le_bytes());
        end.extend_from_slice(&directory_start.to_le_bytes());
        end.extend_from_slice(&[0; 2]);
        self.out.write_all(&end)?;
        self.out.flush()?;
        Ok((self.out.inner, self.out.written))
    }

    fn offset(&self) -> io::Result<u32> {
        as_u32(self.out.written)
    }

    fn local_header(&mut self, name: &str, flags: u16, method: u16, time: (u16, u16)) -> io::Result<()> {
        let mut header = Vec::with_capacity(30 + name.len());
        header.extend_from_slice(&LOCAL_HEADER.to_le_bytes());
        header.extend_from_slice(&VERSION.to_le_bytes());
        header.extend_from_slice(&flags.to_le_bytes());
        header.extend_from_slice(&method.to_le_bytes());
        header.extend_from_slice(&time.0.to_le_bytes());
        header.extend_from_slice(&time.1.to_le_bytes());
        header.extend_from_slice(&[0; 12]);
        header.extend_from_slice(&u16::try_from(name.len()).map_err(|_| io::Error::other(LimitExceeded))?.to_le_bytes());
        header.extend_from_slice(&[0; 2]);
        header.extend_from_slice(name.as_bytes());
        self.out.write_all(&header)
    }
}

fn central_record(entry: &Entry) -> Vec<u8> {
    let (flags, method) = if entry.folder { (FLAGS_FOLDER, STORED) } else { (FLAGS_FILE, DEFLATED) };
    let mut record = Vec::with_capacity(46 + entry.name.len());
    record.extend_from_slice(&CENTRAL_HEADER.to_le_bytes());
    record.extend_from_slice(&VERSION.to_le_bytes());
    record.extend_from_slice(&VERSION.to_le_bytes());
    record.extend_from_slice(&flags.to_le_bytes());
    record.extend_from_slice(&method.to_le_bytes());
    record.extend_from_slice(&entry.time.to_le_bytes());
    record.extend_from_slice(&entry.date.to_le_bytes());
    record.extend_from_slice(&entry.crc.to_le_bytes());
    record.extend_from_slice(&entry.compressed.to_le_bytes());
    record.extend_from_slice(&entry.uncompressed.to_le_bytes());
    record.extend_from_slice(&(entry.name.len() as u16).to_le_bytes());
    record.extend_from_slice(&[0; 8]);
    record.extend_from_slice(&(if entry.folder { FOLDER_ATTRIBUTE } else { 0 }).to_le_bytes());
    record.extend_from_slice(&entry.offset.to_le_bytes());
    record.extend_from_slice(entry.name.as_bytes());
    record
}

fn as_u32(value: u64) -> io::Result<u32> {
    u32::try_from(value).map_err(|_| io::Error::other(LimitExceeded))
}

/// The MS-DOS time and date a ZIP records, from seconds since the Unix epoch. Anything outside 1980 to 2107 is clamped.
pub fn dos_time(unix_seconds: i64) -> (u16, u16) {
    let days = unix_seconds.div_euclid(86_400);
    let seconds_of_day = unix_seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    if year < 1980 {
        return (0, (1 << 5) | 1);
    }
    if year > 2107 {
        return ((23 << 11) | (59 << 5) | 29, (127 << 9) | (12 << 5) | 31);
    }
    let (hour, minute, second) = (seconds_of_day / 3600, seconds_of_day % 3600 / 60, seconds_of_day % 60);
    let time = (hour << 11) | (minute << 5) | (second / 2);
    let date = ((year - 1980) << 9) | (i64::from(month) << 5) | i64::from(day);
    (time as u16, date as u16)
}

#[cfg(test)]
pub(crate) mod tests;
