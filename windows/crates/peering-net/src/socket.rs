//! Socket options every protocol connection needs before TLS wraps it.

use std::io;

use tokio::net::TcpStream;

/// Turns Nagle's algorithm off. With it on, a small control frame waits for the previous segment's ack, which costs about
/// 40 ms per hop; `docs/protocol.md` section 2 requires it off on every socket.
pub fn disable_nagle(stream: &TcpStream) -> io::Result<()> {
    stream.set_nodelay(true)
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
}
