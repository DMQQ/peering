//! `peeringd` — the relay that lets a phone reach its Mac from outside the local network.
//!
//! # What this is
//!
//! Two ends, each behind a NAT that will not admit unsolicited traffic, both connect *outward* to
//! this process. It introduces them (signalling), splices their control connections (TCP), and
//! forwards their video datagrams (UDP).
//!
//! Both ends address the relay, and for most of this project's life neither learned the other's
//! address at all — the relay was the only thing that knew both, which is what lets a session open
//! between two machines neither of which can be dialled. That is still how a session *starts*. What
//! changed is that either end may now ask (`requestPeerAddress`) and be told where its peer was last
//! seen, so the two can try a path between themselves and keep this one as the fallback. The relay
//! hands over an observation and no promise: whether a peer's NAT will admit a third party is not
//! something this process can know, and the two ends settle it by trying. Nothing below about what
//! the relay can and cannot read changes — a direct path is sealed with the same key it was never
//! told, and this is why the claim that follows is about *reading*, never about *carrying*.
//!
//! # What this is not
//!
//! **It is not a security boundary, and nothing here should ever become one.** The relay cannot
//! read what it carries. Control is a TLS session belonging to the two ends, which the relay copies
//! without terminating; video is sealed with a key the two ends exchanged over that TLS session
//! block by block, and which the relay was never told. It reads one thing: the sixteen-byte token
//! that opens a video datagram, which is what a shared video port routes on, and, behind it, the
//! counter the two ends order frames with. Both are addressing and sequencing hints rather than
//! credentials — see the module comment on `session` — and everything after them is ciphertext this
//! process has no key for.
//!
//! That property is the product. "Your Mac's screen does not pass through our servers in a form we
//! can see" is a claim that has to stay true as this code grows, and the way to keep it true is to
//! keep this process too stupid to break it.

pub mod apns;
pub mod config;
pub mod counted_stream;
pub mod device_bindings;
pub mod device_proof;
pub mod fcm;
pub mod fcm_auth;
pub mod playbilling;
pub mod protocol;
pub mod push;
pub mod quota;
pub mod referrals;
pub mod session;
pub mod signalling;
pub mod storekit;
pub mod tcp_relay;
pub mod udp_relay;
pub mod web;
