//! Serves the phone's web preview: fetches from this PC's own loopback on the phone's behalf, and from nowhere else.
//! A redirect is passed to the page rather than followed, since following it here could leave loopback.

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::ErrorKind;
use std::net::Ipv4Addr;
use std::rc::Rc;
use std::time::Duration;

use peering_core::preview::exchange::{request_bytes, ResponseReader};
use peering_core::preview::policy;
use peering_core::preview::transfer::Transfer;
use peering_wire::preview::{
    PreviewFailure, PreviewProxyCommand, PreviewProxyEvent, PreviewProxyRequest, MAX_IN_FLIGHT_PER_CLIENT,
};
use peering_wire::framing::{Frame, MessageKind};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::task::{spawn_local, AbortHandle};
use tokio::time::{timeout, timeout_at, Instant};

use super::outbound::FrameSender;

/// Between two reads, as `URLRequest.timeoutInterval` counts it.
const IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const TOTAL_TIMEOUT: Duration = Duration::from_secs(120);
const READ_BYTES: usize = 16 * 1024;
/// A transfer reads loopback again only once the connection's queue is below this, far under its 16 MB limit, so a
/// fast local server cannot end the session by outrunning the phone.
const QUEUED_BYTES_BEFORE_READ: usize = 1024 * 1024;

/// One connection's open transfers by request id. The runtime is one thread, so a `RefCell` is enough.
#[derive(Clone, Default)]
pub struct PreviewTransfers(Rc<RefCell<HashMap<u32, AbortHandle>>>);

impl PreviewTransfers {
    pub fn handle(&self, command: PreviewProxyCommand, listening_port: u16, outbound: &FrameSender) {
        match command {
            PreviewProxyCommand::Fetch { request } => self.fetch(request, listening_port, outbound.clone()),
            PreviewProxyCommand::Cancel { id } => {
                if let Some(transfer) = self.0.borrow_mut().remove(&id) {
                    transfer.abort();
                }
            }
        }
    }

    /// Drops every transfer, silently: the phone is gone.
    pub fn cancel_all(&self) {
        for (_, transfer) in self.0.borrow_mut().drain() {
            transfer.abort();
        }
    }

    fn fetch(&self, request: PreviewProxyRequest, listening_port: u16, outbound: FrameSender) {
        let id = request.id;
        if let Some(refusal) = policy::refusal(&request, listening_port) {
            send(&outbound, &PreviewProxyEvent::Failure { id, reason: refusal });
            return;
        }
        let mut open = self.0.borrow_mut();
        open.retain(|_, transfer| !transfer.is_finished());
        if open.len() >= MAX_IN_FLIGHT_PER_CLIENT || open.contains_key(&id) {
            send(&outbound, &PreviewProxyEvent::Failure { id, reason: PreviewFailure::Busy });
            return;
        }
        let table = self.0.clone();
        let task = spawn_local(async move {
            if let Err(reason) = run(&request, &outbound).await {
                // A closed connection has nobody to tell.
                let _told = send(&outbound, &PreviewProxyEvent::Failure { id, reason });
            }
            table.borrow_mut().remove(&id);
        });
        open.insert(id, task.abort_handle());
    }
}

async fn run(request: &PreviewProxyRequest, outbound: &FrameSender) -> Result<(), PreviewFailure> {
    let deadline = Instant::now() + TOTAL_TIMEOUT;
    let connecting = TcpStream::connect((Ipv4Addr::LOCALHOST, request.port));
    let mut stream = match timeout(IDLE_TIMEOUT, connecting).await {
        Err(_) => return Err(PreviewFailure::TimedOut),
        Ok(Err(error)) if error.kind() == ErrorKind::ConnectionRefused => return Err(PreviewFailure::NotListening),
        Ok(Err(_)) => return Err(PreviewFailure::Failed),
        Ok(Ok(stream)) => stream,
    };
    // Nagle holds a small request back by up to 40ms per write, which a page of many requests pays for each one.
    let _no_delay = stream.set_nodelay(true);
    stream.write_all(&request_bytes(request)).await.map_err(|_| PreviewFailure::Failed)?;
    let mut reader = ResponseReader::new(&request.method);
    let mut transfer = Transfer::new(request.id);
    let mut buffer = vec![0u8; READ_BYTES];
    while !transfer.is_finished() {
        timeout_at(deadline, outbound.room_for(QUEUED_BYTES_BEFORE_READ)).await.map_err(|_| PreviewFailure::TimedOut)?;
        if outbound.is_closed() {
            return Ok(());
        }
        let idle = Instant::now() + IDLE_TIMEOUT;
        let read = timeout_at(idle.min(deadline), stream.read(&mut buffer)).await.map_err(|_| PreviewFailure::TimedOut)?;
        let pieces = match read {
            Ok(0) => reader.finish(),
            Ok(count) => reader.feed(&buffer[..count]),
            Err(_) => return Err(PreviewFailure::Failed),
        }
        .map_err(|_| PreviewFailure::Failed)?;
        let closed = matches!(read, Ok(0));
        for event in transfer.accept(pieces) {
            if !send(outbound, &event) {
                return Ok(());
            }
        }
        if closed && !transfer.is_finished() {
            return Err(PreviewFailure::Failed);
        }
    }
    Ok(())
}

/// False once the connection is closed or its queue overflowed: there is nobody left to send the rest to.
fn send(outbound: &FrameSender, event: &PreviewProxyEvent) -> bool {
    // Derived Serialize with string keys only, which cannot fail.
    let payload = serde_json::to_vec(event).expect("preview events always serialise");
    outbound.send(Frame::new(MessageKind::PreviewEvent, payload)).is_ok()
}

#[cfg(test)]
mod tests;
