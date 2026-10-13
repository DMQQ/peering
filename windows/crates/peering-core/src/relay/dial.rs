//! Dialling the relay's control port for a ready session: the 16 byte session token goes first, in the clear, and the
//! TLS handshake and the connection role follow on the same connection.

use peering_wire::framing::ConnectionRole;
use thiserror::Error;

use super::registration::RelaySession;
use crate::ports::stream::{ByteStream, StreamError};

pub const TOKEN_LENGTH: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DialError {
    #[error("the relay gave an empty host name")]
    EmptyHost,
    #[error("the relay gave port 0")]
    PortZero,
    #[error("the session token is {0} bytes, not 16")]
    TokenLength(usize),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DialPlan {
    pub host: String,
    pub port: u16,
    pub token: [u8; TOKEN_LENGTH],
    pub then_role: ConnectionRole,
}

/// What to do for a session the relay has said is ready on the control port.
pub fn plan(session: &RelaySession) -> Result<DialPlan, DialError> {
    let token = session.control_token.0;
    checked_plan(&session.control_host, session.control_port, &token)
}

/// The same validation for a token that arrived as raw bytes, where its length is not fixed by the type.
pub fn plan_with_token(host: &str, port: u16, token: &[u8]) -> Result<DialPlan, DialError> {
    checked_plan(host, port, token)
}

fn checked_plan(host: &str, port: u16, token: &[u8]) -> Result<DialPlan, DialError> {
    if host.is_empty() {
        return Err(DialError::EmptyHost);
    }
    if port == 0 {
        return Err(DialError::PortZero);
    }
    let token: [u8; TOKEN_LENGTH] = token.try_into().map_err(|_| DialError::TokenLength(token.len()))?;
    Ok(DialPlan { host: host.to_owned(), port, token, then_role: ConnectionRole::Control })
}

/// The bytes written before anything else on the new connection: exactly the token.
pub fn first_bytes(plan: &DialPlan) -> Vec<u8> {
    plan.token.to_vec()
}

/// An established connection whose token has been written. Everything after that goes through this wrapper.
pub struct RelayControlStream<S: ByteStream> {
    inner: S,
}

impl<S: ByteStream> RelayControlStream<S> {
    pub fn open(plan: &DialPlan, mut stream: S) -> Result<Self, StreamError> {
        stream.send(&first_bytes(plan))?;
        Ok(Self { inner: stream })
    }

    pub fn into_inner(self) -> S {
        self.inner
    }
}

impl<S: ByteStream> ByteStream for RelayControlStream<S> {
    fn send(&mut self, bytes: &[u8]) -> Result<(), StreamError> {
        self.inner.send(bytes)
    }

    fn receive(&mut self) -> Result<Option<Vec<u8>>, StreamError> {
        self.inner.receive()
    }

    fn close(&mut self) {
        self.inner.close();
    }

    fn peer_public_key(&self) -> Option<Vec<u8>> {
        self.inner.peer_public_key()
    }
}

#[cfg(test)]
mod tests;
