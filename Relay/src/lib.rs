//! `peeringd` — the relay that lets a phone reach its Mac from outside the local network.
//!
//! # What this is
//!
//! Two ends, each behind a NAT that will not admit unsolicited traffic, both connect *outward* to
//! this process. It introduces them (signalling), splices their control connections (TCP), and
//! forwards their video datagrams (UDP). Neither end ever learns the other's address, because
//! neither end needs to: both address the relay.
//!
//! # What this is not
//!
//! **It is not a security boundary, and nothing here should ever become one.** The relay cannot
//! read a single byte of what it carries. Control is a TLS session belonging to the two ends,
//! which the relay copies without terminating; video is sealed with a key the two ends exchanged
//! over that TLS session block by block, and which the relay was never told. Its tokens are
//! addressing hints, not credentials — see the module comment on `session`.
//!
//! That property is the product. "Your Mac's screen does not pass through our servers in a form we
//! can see" is a claim that has to stay true as this code grows, and the way to keep it true is to
//! keep this process too stupid to break it.

pub mod config;
pub mod protocol;
pub mod quota;
pub mod session;
pub mod signalling;
pub mod storekit;
pub mod tcp_relay;
pub mod udp_relay;
pub mod web;
