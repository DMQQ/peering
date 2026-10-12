//! A stream that counts what is read from it, so a spliced session's byte total survives the splice failing.

use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// `copy_bidirectional` reports its totals only when it succeeds, and a reset peer is the ordinary way a session ends, so the count is kept here instead.
pub struct CountedStream<S> {
    inner: S,
    read: Arc<AtomicU64>,
    watch: Option<(Arc<EndWatch>, Side)>,
    activity: Option<Arc<Activity>>,
}

/// Which of a splice's two sockets an event happened on, in the order they presented the token.
/// The relay cannot tell a phone from a Mac here (the token is shared and the rest is TLS), so
/// arrival order is the only honest name for them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    First,
    Second,
}

/// Remembers which side of a splice ended first, by end-of-stream or by error on either direction.
#[derive(Default)]
pub struct EndWatch {
    // 0 = nothing yet, 1 = first, 2 = second. Only the first writer wins.
    first: AtomicU8,
}

impl EndWatch {
    fn note(&self, side: Side) {
        let code = match side {
            Side::First => 1,
            Side::Second => 2,
        };
        let _ = self.first.compare_exchange(0, code, Ordering::Relaxed, Ordering::Relaxed);
    }

    pub fn first_to_end(&self) -> Option<Side> {
        match self.first.load(Ordering::Relaxed) {
            1 => Some(Side::First),
            2 => Some(Side::Second),
            _ => None,
        }
    }
}

/// When bytes last crossed a splice in either direction. Kept as an offset from a fixed start so one
/// atomic holds it, and every question takes the current time as an argument so a test can ask in
/// the future instead of waiting.
pub struct Activity {
    base: Instant,
    last_millis: AtomicU64,
}

impl Activity {
    pub fn new() -> Self {
        Self { base: Instant::now(), last_millis: AtomicU64::new(0) }
    }

    fn touch(&self) {
        self.touch_at(Instant::now());
    }

    fn touch_at(&self, now: Instant) {
        let millis = now.saturating_duration_since(self.base).as_millis() as u64;
        self.last_millis.fetch_max(millis, Ordering::Relaxed);
    }

    /// The moment bytes last crossed, or the splice's start if none has.
    pub fn last(&self) -> Instant {
        self.base + Duration::from_millis(self.last_millis.load(Ordering::Relaxed))
    }

    pub fn idle_at(&self, now: Instant) -> Duration {
        now.saturating_duration_since(self.last())
    }
}

impl Default for Activity {
    fn default() -> Self {
        Self::new()
    }
}

impl<S> CountedStream<S> {
    pub fn new(inner: S, read: Arc<AtomicU64>) -> Self {
        Self { inner, read, watch: None, activity: None }
    }

    pub fn active(mut self, activity: Arc<Activity>) -> Self {
        self.activity = Some(activity);
        self
    }

    pub fn watched(mut self, watch: Arc<EndWatch>, side: Side) -> Self {
        self.watch = Some((watch, side));
        self
    }

    fn note_end(&self) {
        if let Some((watch, side)) = &self.watch {
            watch.note(*side);
        }
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for CountedStream<S> {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let before = buf.filled().len();
        let poll = Pin::new(&mut self.inner).poll_read(cx, buf);
        match &poll {
            Poll::Ready(Ok(())) => {
                let got = buf.filled().len() - before;
                self.read.fetch_add(got as u64, Ordering::Relaxed);
                if let (true, Some(activity)) = (got > 0, &self.activity) {
                    activity.touch();
                }
                if got == 0 && buf.remaining() > 0 {
                    self.note_end();
                }
            }
            Poll::Ready(Err(_)) => self.note_end(),
            Poll::Pending => {}
        }
        poll
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for CountedStream<S> {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, data: &[u8]) -> Poll<io::Result<usize>> {
        let poll = Pin::new(&mut self.inner).poll_write(cx, data);
        if let Poll::Ready(Err(_)) = poll {
            self.note_end();
        }
        poll
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn counts_what_was_read_and_not_what_was_written() {
        let (near, mut far) = tokio::io::duplex(64);
        let read = Arc::new(AtomicU64::new(0));
        let mut counted = CountedStream::new(near, Arc::clone(&read));

        far.write_all(b"hello").await.unwrap();
        let mut buf = [0u8; 5];
        counted.read_exact(&mut buf).await.unwrap();
        counted.write_all(b"ignored").await.unwrap();

        assert_eq!(read.load(Ordering::Relaxed), 5);
    }

    #[test]
    fn idleness_is_measured_from_the_last_touch_and_never_goes_backwards() {
        let activity = Activity::new();
        let start = activity.last();
        assert_eq!(activity.idle_at(start + Duration::from_secs(30)), Duration::from_secs(30));

        activity.touch_at(start + Duration::from_secs(20));
        assert_eq!(activity.idle_at(start + Duration::from_secs(30)), Duration::from_secs(10));

        activity.touch_at(start + Duration::from_secs(5));
        assert_eq!(activity.last(), start + Duration::from_secs(20), "an older touch does not rewind it");
    }

    #[tokio::test]
    async fn reading_bytes_in_either_stream_counts_as_activity_and_end_of_stream_does_not() {
        let (near_a, mut far_a) = tokio::io::duplex(64);
        let (near_b, far_b) = tokio::io::duplex(64);
        let activity = Arc::new(Activity::new());
        let mut a = CountedStream::new(near_a, Arc::default()).active(Arc::clone(&activity));
        let mut b = CountedStream::new(near_b, Arc::default()).active(Arc::clone(&activity));
        let start = activity.last();

        drop(far_b);
        let mut buf = [0u8; 1];
        assert_eq!(b.read(&mut buf).await.unwrap(), 0);
        assert_eq!(activity.last(), start, "end of stream is not traffic");

        tokio::time::sleep(Duration::from_millis(5)).await;
        far_a.write_all(b"x").await.unwrap();
        a.read_exact(&mut buf).await.unwrap();
        assert!(activity.last() > start, "bytes read are traffic");
    }

    #[tokio::test]
    async fn remembers_which_side_reached_end_of_stream_first() {
        let (near_a, far_a) = tokio::io::duplex(64);
        let (near_b, mut far_b) = tokio::io::duplex(64);
        let watch = Arc::new(EndWatch::default());
        let mut first = CountedStream::new(near_a, Arc::default()).watched(Arc::clone(&watch), Side::First);
        let mut second = CountedStream::new(near_b, Arc::default()).watched(Arc::clone(&watch), Side::Second);
        assert_eq!(watch.first_to_end(), None);

        far_b.write_all(b"x").await.unwrap();
        let mut buf = [0u8; 1];
        second.read_exact(&mut buf).await.unwrap();
        assert_eq!(watch.first_to_end(), None, "data is not an end");

        drop(far_a);
        assert_eq!(first.read(&mut buf).await.unwrap(), 0);
        drop(far_b);
        assert_eq!(second.read(&mut buf).await.unwrap(), 0);
        assert_eq!(watch.first_to_end(), Some(Side::First), "the later end does not displace the earlier");
    }
}
