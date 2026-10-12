//! Receives Claude Code hooks on 127.0.0.1. A hook process posts its JSON line with the token this server minted and
//! waits for the answer, which is the reply line, or nothing so that Claude Code shows its own dialog.

use std::io;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use peering_core::terminal::hooks::broker::Reply;
use peering_core::terminal::hooks::event::HookEvent;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

use super::request::{head_end, parse_head, Refusal, MAXIMUM_HEAD_BYTES};

/// A hook line is a tool call and its input: well under this, and anything larger is not one.
pub const MAXIMUM_BODY_BYTES: usize = 512 * 1024;
const READ_DEADLINE: Duration = Duration::from_secs(5);

pub type Handler = Arc<dyn Fn(HookEvent, Reply) + Send + Sync>;

#[derive(Clone)]
pub struct HookServerConfig {
    pub token: String,
    /// Longest a hook waits for its answer. The broker answers sooner; this only frees a connection it forgot.
    pub reply_deadline: Duration,
}

pub struct HookServer {
    port: u16,
    accepting: JoinHandle<()>,
}

impl HookServer {
    /// Binds loopback on `port`, or on any free port when it is 0.
    pub async fn start(port: u16, config: HookServerConfig, handler: Handler) -> io::Result<Self> {
        let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, port))).await?;
        let port = listener.local_addr()?.port();
        let accepting = tokio::spawn(accept_loop(listener, config, handler));
        Ok(Self { port, accepting })
    }

    pub fn port(&self) -> u16 {
        self.port
    }
}

impl Drop for HookServer {
    fn drop(&mut self) {
        self.accepting.abort();
    }
}

async fn accept_loop(listener: TcpListener, config: HookServerConfig, handler: Handler) {
    while let Ok((stream, _)) = listener.accept().await {
        tokio::spawn(serve(stream, config.clone(), handler.clone()));
    }
}

async fn serve(mut stream: TcpStream, config: HookServerConfig, handler: Handler) {
    let outcome = match tokio::time::timeout(READ_DEADLINE, read_event(&mut stream, &config.token)).await {
        Ok(outcome) => outcome,
        Err(_) => Err(Refusal::Malformed),
    };
    let response = match outcome {
        Err(refusal) => respond(refusal.status_line(), &[]),
        Ok(event) => {
            let (sender, receiver) = oneshot::channel();
            handler(event, Box::new(move |reply| drop(sender.send(reply))));
            match tokio::time::timeout(config.reply_deadline, receiver).await {
                Ok(Ok(Some(line))) => respond("200 OK", &line),
                _ => respond("204 No Content", &[]),
            }
        }
    };
    drop(stream.write_all(&response).await);
    drop(stream.shutdown().await);
    drain(&mut stream).await;
}

/// Closing with the rest of a refused body unread resets the connection, and the reset discards the status line the
/// hook was about to read.
async fn drain(stream: &mut TcpStream) {
    let mut sink = [0u8; 8192];
    let reading = async { while matches!(stream.read(&mut sink).await, Ok(count) if count > 0) {} };
    drop(tokio::time::timeout(Duration::from_secs(1), reading).await);
}

async fn read_event(stream: &mut TcpStream, token: &str) -> Result<HookEvent, Refusal> {
    let mut received = Vec::new();
    let mut chunk = [0u8; 4096];
    let (head_length, content_length) = loop {
        if let Some(end) = head_end(&received) {
            break (end, parse_head(&received[..end], token, MAXIMUM_BODY_BYTES)?.content_length);
        }
        if received.len() > MAXIMUM_HEAD_BYTES {
            return Err(Refusal::TooLarge);
        }
        let count = stream.read(&mut chunk).await.map_err(|_| Refusal::Malformed)?;
        if count == 0 {
            return Err(Refusal::Malformed);
        }
        received.extend_from_slice(&chunk[..count]);
    };
    while received.len() < head_length + content_length {
        let count = stream.read(&mut chunk).await.map_err(|_| Refusal::Malformed)?;
        if count == 0 {
            return Err(Refusal::Malformed);
        }
        received.extend_from_slice(&chunk[..count]);
    }
    HookEvent::parse(&received[head_length..head_length + content_length]).ok_or(Refusal::Malformed)
}

fn respond(status: &str, body: &[u8]) -> Vec<u8> {
    let mut response =
        format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len())
            .into_bytes();
    response.extend_from_slice(body);
    response
}
