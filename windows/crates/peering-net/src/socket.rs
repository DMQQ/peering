//! Socket options every protocol connection needs before TLS wraps it.

use std::io;
use std::time::Duration;

use socket2::{SockRef, TcpKeepalive};
use tokio::net::TcpStream;

/// Idle time before the first probe, and the gap between probes. A phone that vanished without closing (Wi-Fi lost, the
/// battery pulled) is found by the OS within about a minute instead of waiting for the application's silence limit.
const KEEPALIVE_IDLE: Duration = Duration::from_secs(20);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(5);

/// Turns Nagle's algorithm off. With it on, a small control frame waits for the previous segment's ack, which costs about
/// 40 ms per hop; `docs/protocol.md` section 2 requires it off on every socket.
pub fn disable_nagle(stream: &TcpStream) -> io::Result<()> {
    stream.set_nodelay(true)
}

/// Makes the OS probe an idle connection so a peer that vanished is noticed.
pub fn enable_keepalive(stream: &TcpStream) -> io::Result<()> {
    let keepalive = TcpKeepalive::new().with_time(KEEPALIVE_IDLE).with_interval(KEEPALIVE_INTERVAL);
    SockRef::from(stream).set_tcp_keepalive(&keepalive)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn an_accepted_and_a_dialled_stream_both_end_up_without_nagle() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("a loopback port binds");
        let address = listener.local_addr().expect("the listener has an address");
        let dialled = TcpStream::connect(address).await.expect("the loopback connects");
        let (accepted, _peer) = listener.accept().await.expect("the connection is accepted");
        assert!(!accepted.nodelay().expect("the option reads"), "a fresh stream has Nagle on");

        disable_nagle(&accepted).expect("the option is set");
        disable_nagle(&dialled).expect("the option is set");

        assert!(accepted.nodelay().expect("the option reads"));
        assert!(dialled.nodelay().expect("the option reads"));
    }

    #[tokio::test]
    async fn keepalive_is_off_on_a_fresh_stream_and_on_after_enabling() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("a loopback port binds");
        let address = listener.local_addr().expect("the listener has an address");
        let _dialled = TcpStream::connect(address).await.expect("the loopback connects");
        let (accepted, _peer) = listener.accept().await.expect("the connection is accepted");
        assert!(!SockRef::from(&accepted).keepalive().expect("the option reads"));

        enable_keepalive(&accepted).expect("the option is set");

        assert!(SockRef::from(&accepted).keepalive().expect("the option reads"));
    }
}
