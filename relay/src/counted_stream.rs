//! A stream that counts what is read from it, so a spliced session's byte total survives the splice failing.

use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// `copy_bidirectional` reports its totals only when it succeeds, and a reset peer is the ordinary way a session ends, so the count is kept here instead.
pub struct CountedStream<S> {
    inner: S,
    read: Arc<AtomicU64>,
    watch: Option<(Arc<EndWatch>, Side)>,
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

impl<S> CountedStream<S> {
    pub fn new(inner: S, read: Arc<AtomicU64>) -> Self {
        Self { inner, read, watch: None }
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
