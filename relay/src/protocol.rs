//! The signalling conversation, as JSON over a WebSocket.
//!
//! This is the only place the two ends and the relay have to agree on a shape, and it is
//! deliberately the smallest part of the system. Signalling carries no media — it introduces two
//! parties and hands out the endpoints they will actually use. Once a session exists, nothing the
//! relay says can affect what the two ends do with it, because every byte that matters is already
//! authenticated between them.
//!
//! Field names are camelCase because the other end is Swift, where `JSONEncoder`'s default is the
//! property name unchanged.

use serde::{Deserialize, Serialize};

use crate::session::Token;

/// What a client — either a Mac or a phone — sends to the relay.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ClientMessage {
    /// A Mac announcing itself. Holding this connection open *is* the Mac's presence: when it
    /// drops, the Mac is offline, and it re-registers when it comes back — on a new address, under
    /// the same device ID.
    ///
    /// **`device_id` on its own is a claim, and these three fields are the evidence.** A device ID
    /// is not a secret and was never meant to be one: it is broadcast in the Mac's Bonjour TXT
    /// record to everyone on the network and printed into the pairing QR code. That was harmless
    /// while the ID was only a name two devices used to find each other, and it stopped being
    /// harmless when this message started writing to a table with it. Anyone who learns an ID could
    /// register it, and `HostRegistry` puts without checking, so a stranger could displace the real
    /// Mac's registration and make it unreachable through the relay until it reconnected.
    ///
    /// The evidence is a signature, not a shared secret, because every device already holds the key
    /// to make one: a long-term P-256 key in the keychain, whose public bytes the pairing handshake
    /// already pins. Nothing new is minted, nothing new is stored, and losing the key is a failure
    /// the app already has, because losing it breaks pairing too.
    ///
    /// All three are `None` in a build that predates this, and that is not a refusal: an id nobody
    /// has proved yet is registered by anyone, exactly as before. What the proof buys is that an id
    /// which has been proved can only be claimed by the device that proved it. See
    /// `device_bindings`, which is where that rule lives and why it is shaped that way.
    RegisterHost {
        device_id: String,
        name: String,
        protocol_version: u16,
        /// Hex of the 65-byte uncompressed P-256 point, `0x04 ‖ X ‖ Y`. The same value the two
        /// devices pin for each other, so a phone that has paired with this Mac is looking at it.
        #[serde(default, deserialize_with = "optional_text")]
        public_key: Option<String>,
        /// Hex of a DER-encoded ECDSA signature over [`Self::proof_payload`].
        #[serde(default, deserialize_with = "optional_text")]
        proof: Option<String>,
        /// Seconds since the Unix epoch, covered by the signature.
        ///
        /// A replayed registration is not much of an attack, since it proves the same key and lands
        /// on the same binding, but it would let a captured message re-register a Mac that is already
        /// connected, which is the displacement this exists to stop. The window is what makes that
        /// replay worthless rather than merely uninteresting. It is a bound on how long a capture
        /// stays useful, not a clock the relay trusts for anything else.
        #[serde(default)]
        proof_time: Option<u64>,
    },

    /// A phone asking where its Mac is.
    ///
    /// `client_id` is the phone's own device ID, which it already broadcasts in its Bonjour TXT
    /// record and which is not a secret. The relay wants it for one reason: to recognise a
    /// reconnecting phone and supersede its previous session rather than accumulate one per
    /// attempt. Nothing here is authorization — see `session.rs`.
    ///
    /// `api_key` is optional. When present and valid it grants unlimited relay time; when absent
    /// or unrecognised the client falls back to whatever its plan allows.
    ///
    /// `plan` is the client's own statement of what it has bought, one of `free`, `relay`, `plus`
    /// or `pro`. It is read leniently and in one direction: anything that is not a name the relay
    /// knows, including nothing at all, is the free allowance, and there is no spelling of
    /// "unlimited" that a client can send its way into. A plan is a hint about how much bandwidth
    /// to meter, which is why an unreadable one is not worth refusing a connection over.
    ///
    /// `jws_representation` is the proof, when the client has one: the signed transaction StoreKit
    /// handed the app for its purchase, which the relay verifies against Apple's root before
    /// believing any of it. `storekit.rs` is where that happens, including the arrangement that
    /// gives a client without one its claimed plan for now and the switch that ends it. Read
    /// leniently for the same reason the plan is: a value that is not a string is not a receipt,
    /// and a client that sends rubbish there is a client on the free allowance.
    ConnectToHost {
        host_id: String,
        client_id: String,
        protocol_version: u16,
        #[serde(default)]
        api_key: Option<String>,
        #[serde(default, deserialize_with = "optional_text")]
        plan: Option<String>,
        #[serde(default, deserialize_with = "optional_text")]
        jws_representation: Option<String>,
        /// The client's proof that it is the device whose ID it announces: the same three fields
        /// the Mac sends when it registers, over a different string. `signalling` checks it, and
        /// what it buys is that relay time is metered against a key rather than against an ID the
        /// app can lose by being reinstalled. See `device_proof::client_payload`.
        ///
        /// Optional, and absent from every build before this one: a client that offers no proof is
        /// metered by its announced id, exactly as it was.
        #[serde(default, deserialize_with = "optional_text")]
        public_key: Option<String>,
        #[serde(default, deserialize_with = "optional_text")]
        proof: Option<String>,
        #[serde(default)]
        proof_time: Option<u64>,
        /// A Google Play purchase token the client presents, and the product it was bought as. Read
        /// only by a relay with a Play verifier configured, and absent from every build that predates
        /// Play. Without a verifier they change nothing.
        #[serde(default, deserialize_with = "optional_text")]
        play_purchase_token: Option<String>,
        #[serde(default, deserialize_with = "optional_text")]
        play_product_id: Option<String>,
    },

    /// A phone asking for its own invite code and what invites have earned it.
    ///
    /// All three proof fields are required, signed over `device_proof::referral_payload("status",
    /// client_id, proof_time)`: bonus time hangs from the device key, never from an announced id.
    /// Absent from every build before invites.
    ReferralStatus {
        client_id: String,
        #[serde(default, deserialize_with = "optional_text")]
        public_key: Option<String>,
        #[serde(default, deserialize_with = "optional_text")]
        proof: Option<String>,
        #[serde(default)]
        proof_time: Option<u64>,
    },

    /// A phone redeeming another device's invite code. Signed over
    /// `device_proof::referral_payload("redeem:" + code, client_id, proof_time)`, with `code`
    /// exactly as sent.
    RedeemReferral {
        client_id: String,
        code: String,
        #[serde(default, deserialize_with = "optional_text")]
        public_key: Option<String>,
        #[serde(default, deserialize_with = "optional_text")]
        proof: Option<String>,
        #[serde(default)]
        proof_time: Option<u64>,
    },

    /// Keeps the signalling connection alive through idle NAT timeouts.
    Ping,

    /// One end asking where the *other* end of its session is.
    ///
    /// **This is the one message that makes the relay's oldest promise false**, so it is worth being
    /// exact about what changes. Until now neither end ever learned the other's address: both
    /// addressed the relay, and the relay was the only thing that knew both. That is what lets a
    /// session open between two machines neither of which can be dialled — and it is also why every
    /// byte goes to Helsinki even when the two ends are in the same city.
    ///
    /// What the answer buys is an *introduction*, not a redirect. Knowing where the peer is lets the
    /// two ends try a path between themselves and fall back to this relay when it does not open, so
    /// the worst case is the behaviour that existed before this message did. The relay is not
    /// asking either end to trust the answer: the two ends authenticate each other with the pairing
    /// handshake they already run over the control channel, and a wrong address simply fails to
    /// answer.
    ///
    /// The asker identifies itself by its own `video_token`, which is the only thing either end
    /// holds that says which of the session's two slots it is. Nothing new is collected to answer
    /// it: the relay already stores each slot's observed source address, because forwarding is
    /// impossible without it.
    RequestPeerAddress {
        /// Hex, and the asking end's own — its peer's address is what comes back.
        video_token: String,
    },

    /// Is this Mac registered with the relay right now?
    ///
    /// **Asked by a phone that has paired with a Mac and cannot see it.** Bonjour answers that
    /// question for a Mac on the same network and answers nothing at all for one that is not, which
    /// is every Mac reached through this relay. So the app had two states, nearby and unknown, and
    /// drew the second one the same way it would draw *offline*: a grey dot on a Mac that was
    /// sitting awake on the other side of the country. This is the smallest question that fixes it.
    ///
    /// It is a question and not a subscription: one ask, one answer, and the registration it reads
    /// is the same one `ConnectToHost` consults before it will open a session. Nothing is stored
    /// about the ask, and the answer says only whether the Mac is here, never where.
    ///
    /// **What it costs is worth naming**, because it is the first message that tells this process
    /// something it did not already need to know: a phone that asks after three Macs has told the
    /// relay which three it is interested in, where before it revealed one at the moment it
    /// connected to it. That is a small disclosure and a real one, and it is why this is a poll the
    /// app runs while the Connect tab is open rather than something it reports continuously.
    HostPresence {
        /// The device id the phone paired with, exactly as it stores it.
        host_id: String,
    },

    /// A registered Mac asking the relay to push an APNs notification to a phone that is no
    /// longer reachable over the control channel. The relay holds the APNs key; the Mac only
    /// knows the device token it received from the phone.
    NotifyDevice {
        device_token: String,
        title: String,
        body: String,
        /// The capture source the notification is about, which the phone shows when it is tapped.
        /// Absent from Macs that predate it.
        #[serde(default)]
        source: Option<String>,
        /// The notification category the phone registered, so the system shows its buttons.
        /// Absent from Macs that predate it.
        #[serde(default)]
        category: Option<String>,
        /// Which agent chat the notification asks about, for a button pressed with the app closed.
        #[serde(default)]
        session_id: Option<String>,
        /// Which approval request within that chat.
        #[serde(default)]
        approval_id: Option<String>,
    },
}

/// What the relay sends back.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ServerMessage {
    /// A host registration was accepted.
    Registered { session_ttl_seconds: u64 },

    /// A session is ready. Sent to the phone that asked and pushed to the Mac it asked for, with
    /// identical contents, because both need exactly the same four things: where to connect and
    /// what to present when they get there.
    ///
    /// The control token is single-use; the video token is reusable, because a NAT mapping can
    /// change mid-session and the binding has to be re-established. See `session.rs`.
    SessionReady {
        control_host: String,
        control_port: u16,
        video_host: String,
        video_port: u16,
        /// Hex.
        control_token: String,
        /// Hex.
        video_token: String,
        /// Seconds of relay time the client's metered plan has left in the current window,
        /// referral bonus included. Absent when the plan is unmetered, which clients read as
        /// unlimited.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        remaining_seconds: Option<u64>,
    },

    /// The Mac is not registered. It is asleep, off, or has not been launched.
    HostOffline { device_id: String },

    /// Where the other end of this session was last seen, as seen from the relay's outside.
    ///
    /// It is the source address of the peer's most recent video datagram, so it is the peer as the
    /// peer's *own* NAT presents it — which is exactly the address anything else on the internet
    /// would have to send to for the packet to be delivered. Whether it is delivered is a different
    /// question, and one the relay cannot answer: a NAT that forwards to the relay need not accept
    /// anything from a third party, and the address the relay saw may have been replaced by a
    /// fresh one for a different destination. That uncertainty is why the two ends prove the path
    /// to each other rather than treating this message as a fact.
    ///
    /// Sent only in answer to [`ClientMessage::RequestPeerAddress`], and only when the peer has
    /// been heard from at all — see the `peerAddressUnknown` error for the other case.
    PeerAddress { host: String, port: u16 },

    /// Whether a Mac is registered, in answer to [`ClientMessage::HostPresence`].
    ///
    /// `online: false` is a fact the relay is entitled to state: it is the same fact that makes
    /// `ConnectToHost` answer [`ServerMessage::HostOffline`], read a moment earlier. It is *not* a
    /// claim that the Mac is switched off, and the app is careful not to draw it as one: a Mac can
    /// be awake and reachable on its own network while being registered nowhere.
    ///
    /// The `host_id` is echoed so an answer can be matched to its question without relying on the
    /// order they arrive in.
    HostPresence { host_id: String, online: bool },

    /// A device's invite standing, in answer to [`ClientMessage::ReferralStatus`] and to a
    /// successful [`ClientMessage::RedeemReferral`].
    ///
    /// `bonus_seconds` is what is added to *each window's* free allowance right now, so the app's
    /// "relay time left" bar is `free allowance + bonus_seconds - used`. `bonus_ends_at` is Unix
    /// seconds and absent when no grant is running.
    Referral {
        code: String,
        bonus_seconds: u64,
        bonus_ends_at: Option<u64>,
        redeemed: bool,
        invites_earned: u32,
        invites_max: u32,
    },

    Pong,

    Error { code: String, message: String },
}

impl ServerMessage {
    pub fn error(code: &str, message: impl Into<String>) -> Self {
        Self::Error {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

/// Reads a string field, and reads anything else as no string at all.
///
/// Used for both of the fields where a client states what it has bought, and the reading is the
/// same for both. A JSON number, object or list where a plan or a receipt should be is not an
/// error, it is nothing: a client that sends one of those is not telling the relay anything about
/// what it bought, and the one outcome that has to be impossible is a value the relay
/// half-understands being taken as a paid plan or as a receipt. `quota.rs` makes the same judgement
/// about plan strings it does not recognise, and `storekit.rs` about receipts that do not verify.
fn optional_text<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Ok(match Option::<serde_json::Value>::deserialize(deserializer)? {
        Some(serde_json::Value::String(text)) => Some(text),
        _ => None,
    })
}

/// Hex, because it needs no dependency, is trivially readable in a log, and these are 16 bytes that
/// travel inside TLS.
pub fn hex(bytes: &Token) -> String {
    use std::fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut out, b| {
            let _ = write!(out, "{b:02x}");
            out
        })
}

pub fn unhex(text: &str) -> Option<Token> {
    if text.len() != 32 {
        return None;
    }
    let mut out = [0u8; 16];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

/// The same encoding for a byte string of any length.
///
/// `hex` and `unhex` above are the token-sized pair and stay as they are, because a token is
/// always exactly sixteen bytes and the fixed size is half of what makes decoding one safe. Keys
/// and signatures are not a fixed size, so they get the general pair rather than a second
/// special case.
pub fn bytes_hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut out, b| {
            let _ = write!(out, "{b:02x}");
            out
        })
}

/// Decodes hex of any even length, and refuses anything else.
///
/// `None` rather than a partial answer for every way this can be wrong: an odd length, a character
/// that is not a hex digit, or a string longer than the caller could possibly want. The length cap
/// is the caller's, passed in, because "too long" means something different for a public key than
/// for a signature and neither number belongs here.
pub fn hex_bytes(text: &str, limit: usize) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 || text.len() > limit * 2 {
        return None;
    }
    let mut out = Vec::with_capacity(text.len() / 2);
    for i in 0..text.len() / 2 {
        out.push(u8::from_str_radix(text.get(i * 2..i * 2 + 2)?, 16).ok()?);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invite_messages_use_camel_case_and_reach_an_old_parser_as_unknown() {
        let text = r#"{"type":"redeemReferral","clientId":"p","code":"ABCDEFGH","publicKey":"04","proof":"30","proofTime":5}"#;
        let message: ClientMessage = serde_json::from_str(text).expect("should parse");
        assert!(matches!(message, ClientMessage::RedeemReferral { ref code, .. } if code == "ABCDEFGH"));

        let reply = serde_json::to_value(ServerMessage::Referral {
            code: "ABCDEFGH".into(),
            bonus_seconds: 1800,
            bonus_ends_at: None,
            redeemed: false,
            invites_earned: 0,
            invites_max: 5,
        })
        .expect("serialises");
        assert_eq!(reply["type"], "referral");
        assert_eq!(reply["bonusSeconds"], 1800);
        assert_eq!(reply["invitesMax"], 5);
        assert!(reply["bonusEndsAt"].is_null());
    }

    #[test]
    fn a_host_registration_round_trips_through_camel_case() {
        let text = r#"{"type":"registerHost","deviceId":"abc","name":"Studio","protocolVersion":3}"#;
        let message: ClientMessage = serde_json::from_str(text).expect("should parse");
        assert_eq!(
            message,
            ClientMessage::RegisterHost {
                device_id: "abc".into(),
                name: "Studio".into(),
                protocol_version: 3,
                // Absent, which is the shape a build that predates the proof sends. It has to parse,
                // because every Mac in the field right now sends exactly this.
                public_key: None,
                proof: None,
                proof_time: None,
            }
        );
    }

    /// And the shape a build that proves itself sends.
    #[test]
    fn a_proved_registration_round_trips_too() {
        let text = r#"{"type":"registerHost","deviceId":"abc","name":"Studio","protocolVersion":14,
            "publicKey":"04aa","proof":"3045","proofTime":1760000000}"#;
        let message: ClientMessage = serde_json::from_str(text).expect("should parse");
        assert_eq!(
            message,
            ClientMessage::RegisterHost {
                device_id: "abc".into(),
                name: "Studio".into(),
                protocol_version: 14,
                public_key: Some("04aa".into()),
                proof: Some("3045".into()),
                proof_time: Some(1_760_000_000),
            }
        );
    }

    #[test]
    fn a_connect_request_round_trips_through_camel_case() {
        let text =
            r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3}"#;
        let message: ClientMessage = serde_json::from_str(text).expect("should parse");
        assert_eq!(
            message,
            ClientMessage::ConnectToHost {
                host_id: "mac".into(),
                client_id: "phone".into(),
                protocol_version: 3,
                api_key: None,
                plan: None,
                jws_representation: None,
                public_key: None,
                proof: None,
                proof_time: None,
                play_purchase_token: None,
                play_product_id: None,
            }
        );
    }

    #[test]
    fn a_connect_request_carries_the_plan_the_client_claims() {
        let text = r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"plan":"pro"}"#;
        let message: ClientMessage = serde_json::from_str(text).expect("should parse");
        assert_eq!(
            message,
            ClientMessage::ConnectToHost {
                host_id: "mac".into(),
                client_id: "phone".into(),
                protocol_version: 3,
                api_key: None,
                plan: Some("pro".into()),
                jws_representation: None,
                public_key: None,
                proof: None,
                proof_time: None,
                play_purchase_token: None,
                play_product_id: None,
            }
        );
    }

    /// The receipt beside the plan, which is the pair `storekit.rs` exists to resolve: the claim
    /// for a client with nothing to prove, and the proof for one that has it.
    #[test]
    fn a_connect_request_carries_the_receipt_beside_the_plan() {
        let text = r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"plan":"pro","jwsRepresentation":"eyJhbGci.eyJidW5kbGUi.c2ln"}"#;
        let message: ClientMessage = serde_json::from_str(text).expect("should parse");
        let ClientMessage::ConnectToHost {
            plan,
            jws_representation,
            ..
        } = message
        else {
            panic!("expected a connect request");
        };

        assert_eq!(plan.as_deref(), Some("pro"));
        assert_eq!(
            jws_representation.as_deref(),
            Some("eyJhbGci.eyJidW5kbGUi.c2ln")
        );
    }

    /// And the same lenient read as the plan, for the same reason: whatever a client puts in that
    /// field, what reaches the verifier is either a string or nothing, and nothing is the claimed
    /// path rather than a parse failure that would refuse the connection.
    #[test]
    fn a_receipt_that_is_not_a_string_arrives_as_no_receipt() {
        for value in ["42", "null", "{}", "[\"eyJ\"]", "true"] {
            let text = format!(
                r#"{{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"jwsRepresentation":{value}}}"#
            );
            let message: ClientMessage = serde_json::from_str(&text).expect("should parse");
            let ClientMessage::ConnectToHost {
                jws_representation,
                ..
            } = message
            else {
                panic!("expected a connect request");
            };
            assert_eq!(jws_representation, None, "receipt {value} should read as none");
        }
    }

    /// Absent and explicitly null both have to mean "no receipt", because the two ends spell it
    /// differently: the Swift side leaves the field out and Rust's own encoder writes the null.
    #[test]
    fn a_connect_request_without_a_receipt_round_trips_as_no_receipt() {
        let message = ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
            api_key: None,
            plan: Some("relay".into()),
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
            play_purchase_token: None,
            play_product_id: None,
        };
        let json = serde_json::to_string(&message).expect("should encode");
        assert_eq!(
            serde_json::from_str::<ClientMessage>(&json).expect("should parse"),
            message
        );

        let explicit_null = r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"plan":"relay","jwsRepresentation":null}"#;
        assert_eq!(
            serde_json::from_str::<ClientMessage>(explicit_null).expect("should parse"),
            message
        );
    }

    /// The lenient read, at the layer where it happens: whatever a client puts in that field, what
    /// arrives at the quota check is either a string it can recognise or nothing at all.
    #[test]
    fn a_plan_that_is_not_a_string_arrives_as_no_plan() {
        for value in ["42", "null", "{}", "[\"pro\"]", "true"] {
            let text = format!(
                r#"{{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"plan":{value}}}"#
            );
            let message: ClientMessage = serde_json::from_str(&text).expect("should parse");
            let ClientMessage::ConnectToHost { plan, .. } = message else {
                panic!("expected a connect request");
            };
            assert_eq!(plan, None, "plan {value} should read as no plan");
        }
    }

    /// A client that says nothing is metered as free rather than refused, and this is the shape
    /// that says nothing: the field left out entirely, or sent as an explicit null. The Swift side
    /// omits it; Rust's own encoder writes the null. Both have to mean None here.
    #[test]
    fn a_connect_request_without_a_plan_round_trips_as_no_plan() {
        let message = ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
            api_key: None,
            plan: None,
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
            play_purchase_token: None,
            play_product_id: None,
        };
        let json = serde_json::to_string(&message).expect("should encode");
        assert_eq!(
            serde_json::from_str::<ClientMessage>(&json).expect("should parse"),
            message
        );

        let explicit_null = r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":3,"plan":null}"#;
        assert_eq!(
            serde_json::from_str::<ClientMessage>(explicit_null).expect("should parse"),
            message
        );
    }

    #[test]
    fn session_ready_reports_its_endpoints_in_the_case_swift_expects() {
        let message = ServerMessage::SessionReady {
            control_host: "relay.example".into(),
            control_port: 9443,
            video_host: "relay.example".into(),
            video_port: 51234,
            control_token: hex(&[0xab; 16]),
            video_token: hex(&[0xcd; 16]),
            remaining_seconds: None,
        };
        let json = serde_json::to_string(&message).expect("should encode");

        for key in [
            "controlHost",
            "controlPort",
            "videoHost",
            "videoPort",
            "controlToken",
            "videoToken",
        ] {
            assert!(json.contains(key), "missing {key} in {json}");
        }
        assert!(!json.contains("remainingSeconds"), "unmetered plans omit the field: {json}");
    }

    #[test]
    fn session_ready_carries_remaining_seconds_when_metered() {
        let message = ServerMessage::SessionReady {
            control_host: "h".into(),
            control_port: 1,
            video_host: "h".into(),
            video_port: 2,
            control_token: hex(&[0xab; 16]),
            video_token: hex(&[0xcd; 16]),
            remaining_seconds: Some(1703),
        };
        let json = serde_json::to_string(&message).expect("should encode");
        assert!(json.contains(r#""remainingSeconds":1703"#), "{json}");
        assert_eq!(serde_json::from_str::<ServerMessage>(&json).unwrap(), message);
    }

    /// The Swift side decodes these by name, so a rename here is a silent break at runtime rather
    /// than a compile error there. This pins the tag as well as the fields.
    #[test]
    fn the_message_tag_is_the_swift_case_name() {
        let json = serde_json::to_string(&ServerMessage::Pong).unwrap();
        assert_eq!(json, r#"{"type":"pong"}"#);

        let json = serde_json::to_string(&ServerMessage::HostOffline {
            device_id: "abc".into(),
        })
        .unwrap();
        assert_eq!(json, r#"{"type":"hostOffline","deviceId":"abc"}"#);
    }

    /// The introduction, pinned in both directions. The Swift side decodes these by name, so a
    /// rename here is a silent break at runtime rather than a compile error there.
    #[test]
    fn a_peer_address_round_trips_and_the_tag_is_the_swift_case_name() {
        let json = serde_json::to_string(&ServerMessage::PeerAddress {
            host: "203.0.113.7".into(),
            port: 51234,
        })
        .expect("should encode");
        assert_eq!(
            json,
            r#"{"type":"peerAddress","host":"203.0.113.7","port":51234}"#
        );

        let text = r#"{"type":"requestPeerAddress","videoToken":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"}"#;
        assert_eq!(
            serde_json::from_str::<ClientMessage>(text).expect("should parse"),
            ClientMessage::RequestPeerAddress {
                video_token: "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd".into(),
            }
        );
    }

    #[test]
    fn tokens_survive_a_round_trip_and_rubbish_is_refused() {
        let token = [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54,
            0x32, 0x10,
        ];
        assert_eq!(unhex(&hex(&token)), Some(token));

        assert_eq!(unhex(""), None);
        assert_eq!(unhex("abcd"), None, "too short");
        assert_eq!(unhex(&"z".repeat(32)), None, "not hex");
        assert_eq!(unhex(&"a".repeat(33)), None, "too long");
        assert_eq!(unhex(&"aB".repeat(16)), Some([0xab; 16]), "either case");
    }

    #[test]
    fn a_connect_without_play_fields_decodes_as_it_always_did() {
        let message: ClientMessage = serde_json::from_str(
            r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":20,"plan":"pro"}"#,
        )
        .expect("an older connect still parses");
        let ClientMessage::ConnectToHost { play_purchase_token, play_product_id, .. } = message else {
            panic!("expected a connect");
        };
        assert_eq!((play_purchase_token, play_product_id), (None, None));
    }

    #[test]
    fn the_play_fields_are_read_and_a_non_text_value_is_absent() {
        let message: ClientMessage = serde_json::from_str(
            r#"{"type":"connectToHost","hostId":"mac","clientId":"phone","protocolVersion":20,"playPurchaseToken":"tok","playProductId":7}"#,
        )
        .expect("parses");
        let ClientMessage::ConnectToHost { play_purchase_token, play_product_id, .. } = message else {
            panic!("expected a connect");
        };
        assert_eq!(play_purchase_token.as_deref(), Some("tok"));
        assert_eq!(play_product_id, None);
    }
}
