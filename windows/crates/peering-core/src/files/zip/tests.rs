use std::io::Read;

use flate2::read::DeflateDecoder;

use super::*;

/// One entry as read back from the central directory, with its content inflated from the local record.
#[derive(Debug, PartialEq)]
pub(crate) struct Found {
    pub name: String,
    pub content: Vec<u8>,
    pub folder: bool,
    pub time: (u16, u16),
}

fn u16_at(bytes: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([bytes[at], bytes[at + 1]])
}

fn u32_at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

/// Reads an archive the way an unzip tool does: from the end-of-directory record, through the central directory, to each
/// local record, checking the checksums the data descriptors promised.
pub(crate) fn read_back(zip: &[u8]) -> Vec<Found> {
    let end = zip.len() - 22;
    assert_eq!(u32_at(zip, end), END_OF_DIRECTORY);
    let count = u16_at(zip, end + 10) as usize;
    let directory_size = u32_at(zip, end + 12) as usize;
    let mut at = u32_at(zip, end + 16) as usize;
    assert_eq!(at + directory_size, end, "the directory ends where the end record begins");
    let mut found = Vec::new();
    for _ in 0..count {
        assert_eq!(u32_at(zip, at), CENTRAL_HEADER);
        let flags = u16_at(zip, at + 8);
        let method = u16_at(zip, at + 10);
        let time = (u16_at(zip, at + 12), u16_at(zip, at + 14));
        let crc = u32_at(zip, at + 16);
        let compressed = u32_at(zip, at + 20) as usize;
        let uncompressed = u32_at(zip, at + 24) as usize;
        let name_length = u16_at(zip, at + 28) as usize;
        let attributes = u32_at(zip, at + 38);
        let local = u32_at(zip, at + 42) as usize;
        let name = String::from_utf8(zip[at + 46..at + 46 + name_length].to_vec()).expect("names are UTF-8");
        assert_ne!(flags & 0x0800, 0, "names are flagged UTF-8");
        assert_eq!(u32_at(zip, local), LOCAL_HEADER);
        let local_name_length = u16_at(zip, local + 26) as usize;
        assert_eq!(&zip[local + 30..local + 30 + local_name_length], name.as_bytes());
        let data = local + 30 + local_name_length;
        let content = if method == DEFLATED {
            let mut inflated = Vec::new();
            DeflateDecoder::new(&zip[data..data + compressed]).read_to_end(&mut inflated).expect("a valid deflate stream");
            assert_eq!(inflated.len(), uncompressed);
            assert_eq!(crc32fast::hash(&inflated), crc);
            let descriptor = data + compressed;
            assert_eq!(u32_at(zip, descriptor), DATA_DESCRIPTOR);
            assert_eq!((u32_at(zip, descriptor + 4), u32_at(zip, descriptor + 8), u32_at(zip, descriptor + 12)), (crc, compressed as u32, uncompressed as u32));
            inflated
        } else {
            assert_eq!((compressed, uncompressed), (0, 0));
            Vec::new()
        };
        found.push(Found { name, content, folder: attributes & FOLDER_ATTRIBUTE != 0, time });
        at += 46 + name_length;
    }
    found
}

fn zip_of(files: &[(&str, &[u8])]) -> Vec<u8> {
    let mut zip = ZipWriter::new(Vec::new(), u64::MAX);
    zip.add_folder("Top/", (0, 33)).unwrap();
    for (name, content) in files {
        let mut source: &[u8] = content;
        zip.add_file(name, (0, 33), &mut source).unwrap();
    }
    zip.finish().unwrap().0
}

#[test]
fn what_goes_in_comes_out_with_its_names_and_content() {
    let big = b"abcdefgh".repeat(100_000);
    let zip = zip_of(&[("Top/a.txt", b"hello"), ("Top/empty", b""), ("Top/big.bin", &big)]);
    let found = read_back(&zip);
    let names: Vec<&str> = found.iter().map(|entry| entry.name.as_str()).collect();
    assert_eq!(names, ["Top/", "Top/a.txt", "Top/empty", "Top/big.bin"]);
    assert!(found[0].folder);
    assert_eq!(found[1].content, b"hello");
    assert!(found[2].content.is_empty());
    assert_eq!(found[3].content, big);
    assert!(zip.len() < big.len() / 4, "repetitive content is compressed");
}

#[test]
fn names_outside_ascii_are_written_as_utf8() {
    let zip = zip_of(&[("Top/zażółć.txt", b"x")]);
    assert_eq!(read_back(&zip)[1].name, "Top/zażółć.txt");
}

#[test]
fn an_empty_archive_is_just_an_end_record() {
    let zip = ZipWriter::new(Vec::new(), u64::MAX).finish().unwrap().0;
    assert_eq!(zip.len(), 22);
    assert!(read_back(&zip).is_empty());
}

#[test]
fn the_size_returned_is_the_size_of_the_archive() {
    let mut zip = ZipWriter::new(Vec::new(), u64::MAX);
    let mut source: &[u8] = b"data";
    zip.add_file("a", (0, 33), &mut source).unwrap();
    let (bytes, size) = zip.finish().unwrap();
    assert_eq!(size, bytes.len() as u64);
}

#[test]
fn an_archive_past_its_cap_fails_with_the_limit_error() {
    let mut zip = ZipWriter::new(Vec::new(), 200);
    let mut state = 0x9E37_79B9_7F4A_7C15u64;
    let noise: Vec<u8> = (0..50_000)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state >> 24) as u8
        })
        .collect();
    let mut source: &[u8] = &noise;
    let error = zip.add_file("noise", (0, 33), &mut source).unwrap_err();
    assert!(is_limit_exceeded(&error));
}

#[test]
fn another_error_is_not_mistaken_for_the_limit() {
    assert!(!is_limit_exceeded(&io::Error::other("disk full")));
}

#[test]
fn the_time_is_stored_in_the_ms_dos_form() {
    // 2021-03-04 05:06:08 UTC.
    let (time, date) = dos_time(1_614_834_368);
    assert_eq!((time >> 11, (time >> 5) & 63, (time & 31) * 2), (5, 6, 8));
    assert_eq!((1980 + (date >> 9), (date >> 5) & 15, date & 31), (2021, 3, 4));
}

#[test]
fn times_before_1980_and_after_2107_are_clamped() {
    assert_eq!(dos_time(0), (0, (1 << 5) | 1));
    assert_eq!(dos_time(-5_000_000_000), (0, (1 << 5) | 1));
    let (_, date) = dos_time(10_000_000_000);
    assert_eq!(1980 + (date >> 9), 2107);
}

#[test]
fn a_leap_day_is_a_day() {
    let (_, date) = dos_time(951_782_400); // 2000-02-29
    assert_eq!((1980 + (date >> 9), (date >> 5) & 15, date & 31), (2000, 2, 29));
}
