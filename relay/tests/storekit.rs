//! Receipts: what the relay believes, what it refuses, and what it does with a client that has
//! nothing to prove.
//!
//! The chain in these tests is generated rather than Apple's — see `support` for why, and for what
//! that does and does not prove. Each test changes exactly one thing about a chain that would
//! otherwise verify, so a failure names the check that broke rather than the fixture that rotted.

mod support;

use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD as BASE64, URL_SAFE};
use futures_util::{SinkExt, StreamExt};
use peeringd::config::PlanAllowances;
use peeringd::protocol::{ClientMessage, ServerMessage};
use peeringd::quota::{Plan, QuotaTracker};
use peeringd::session::Registry;
use peeringd::signalling::{HostRegistry, Settings};
use peeringd::storekit::{
    APPLE_ROOT_CA_G3_SHA256, APP_BUNDLE_ID, MAX_JWS_BYTES, Rejection, StoreKitVerifier, Trust,
};
use peeringd::signalling;
use support::{
    ChainOptions, TestChain, environmentless_transaction, revoked_transaction, sandbox_transaction,
    transaction,
};
use tokio::net::TcpListener;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;
use x509_cert::der::Decode as _;

/// Generous enough for a loaded machine, short enough that a hang fails the test.
const PATIENCE: Duration = Duration::from_secs(5);

/// Standard base64, which is what `x5c` holds.
fn base64(bytes: &[u8]) -> String {
    BASE64.encode(bytes)
}

/// base64url, which is what a JWS segment is.
fn base64_url(bytes: &[u8]) -> String {
    URL_SAFE.encode(bytes)
}

/// The products, and the plan each one buys, as the app spells them.
const PRODUCTS: [(&str, &str); 4] = [
    ("pl.dmq.peering.iap.relay.monthly", "relay"),
    ("pl.dmq.peering.iap.relay.year", "relay"),
    ("pl.dmq.peering.iap.pro.monthly", "pro"),
    ("pl.dmq.peering.iap.pro.year", "pro"),
];

// MARK: - The pinned root

/// The trust anchor is a file in the repository, and this test is what stops it being replaced.
///
/// **It cannot prove the file is Apple's**, and it is worth being straight about that rather than
/// implying otherwise: the same repository holds the fingerprint and the file, so all this
/// establishes is that the two still agree. What makes it Apple's root is that it was downloaded
/// from Apple's certificate authority page over HTTPS, and what the check buys is the property a
/// pin needs — a truncated, corrupted or substituted file fails here, and would otherwise have
/// anchored every receipt to something that is not Apple, silently and for as long as nobody
/// looked.
///
/// The second half of the test is independent of the fingerprint: the file has to be a certificate,
/// and the one it has to be. That catches a substitution the fingerprint would not — a file swapped
/// along with the constant — and it pins the name, the issuer and the extensions that make the
/// "root as its own leaf" path fail even before the marker check does.
#[test]
fn the_pinned_root_is_the_file_this_repository_pins_and_is_apples_root() {
    let der: &[u8] = include_bytes!("../src/AppleRootCA-G3.cer");

    let digest = ring::digest::digest(&ring::digest::SHA256, der);
    assert_eq!(
        digest.as_ref(),
        &APPLE_ROOT_CA_G3_SHA256[..],
        "the file in src/ is not the one this constant names"
    );

    let root = x509_cert::Certificate::from_der(der)
        .expect("the pinned root should parse as a certificate");
    let name = |field: &x509_cert::name::Name| {
        field
            .to_string()
            .split(',')
            .map(|part| part.trim().to_string())
            .collect::<Vec<_>>()
    };

    assert_eq!(
        name(root.tbs_certificate().subject()),
        ["C=US", "O=Apple Inc.", "OU=Apple Certification Authority", "CN=Apple Root CA - G3"],
        "the pinned root should be the certificate Apple publishes under this name"
    );
    assert_eq!(
        root.tbs_certificate().issuer(),
        root.tbs_certificate().subject(),
        "Apple's root is self-issued"
    );

    // And it carries none of the receipt markers, which is the second reason a client cannot send
    // the pinned root as its own signing certificate.
    let extensions = root.tbs_certificate().extensions();
    let oids: Vec<String> = extensions
        .iter()
        .flat_map(|extensions| extensions.iter())
        .map(|extension| extension.extn_id.to_string())
        .collect();
    assert!(
        !oids.iter().any(|oid| oid.starts_with("1.2.840.113635.100.6.")),
        "Apple's root should carry no Apple marker extensions, found {oids:?}"
    );
}

/// And a verifier anchored to a *different* root refuses the chain, which is the property the pin
/// exists for: a chain is the sender's claim until it reaches a key we already had.
#[test]
fn a_chain_is_worth_nothing_against_someone_elses_root() {
    let attacker = TestChain::genesis();
    let receipt = attacker.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    // The attacker's own verifier, anchored to their root, is happy. That is the point: the
    // signature is real, the chain is real, and neither of them is Apple.
    assert_eq!(attacker.verifier(true).verify(&receipt), Ok(Plan::Pro));

    let relay = TestChain::genesis().verifier(true);
    assert_eq!(relay.verify(&receipt), Err(Rejection::UntrustedChain));
}

// MARK: - The chain

/// The happy path, for each of the three products in turn. This is the test that would fail first
/// if the relay stopped understanding receipts at all.
#[test]
fn a_receipt_that_chains_to_the_pinned_root_buys_the_product_it_names() {
    let chain = TestChain::genesis();
    let relay = chain.verifier(true);

    for (product, plan) in PRODUCTS {
        let receipt = chain.jws(&transaction(APP_BUNDLE_ID, product, 30));
        let verified = relay.verify(&receipt).unwrap_or_else(|rejection| {
            panic!("{product} should verify, got {}", rejection.reason())
        });
        assert_eq!(verified.as_str(), plan);

        // And through the resolution the relay actually uses, which is where the log vocabulary
        // comes from.
        let resolved = relay.resolve(Plan::Free, Some(Ok(verified)));
        assert_eq!(resolved.plan, verified);
        assert_eq!(resolved.trust, Trust::Verified);
        assert_eq!(resolved.rejected, None);
    }
}

/// The pinned root does not have to be in the receipt. Apple sends it, and a chain that stops at
/// the intermediate is the same chain — the anchor is the copy in this repository either way, which
/// is the whole point of pinning one. Both shapes have to verify, because which one Apple sends is
/// not something that can be checked from here.
#[test]
fn the_root_may_be_in_the_chain_or_left_out_of_it() {
    let chain = TestChain::genesis();
    let payload = transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30);

    for (label, x5c) in [
        (
            "leaf and intermediate",
            vec![base64(chain.leaf.as_ref()), base64(chain.intermediate.as_ref())],
        ),
        ("the whole chain", chain.x5c()),
    ] {
        let header = serde_json::json!({ "alg": "ES256", "x5c": x5c });
        let receipt = chain.jws_with(&header, &payload);
        assert_eq!(
            chain.verifier(true).verify(&receipt),
            Ok(Plan::Pro),
            "{label} should verify"
        );
    }
}

/// Apple's leaf carries an extended key usage; the verifier deliberately does not require one, and
/// this pins both halves of that decision so neither is mistaken for an oversight later.
#[test]
fn the_leafs_extended_key_usage_does_not_decide_anything() {
    for eku in [None, Some(rcgen::ExtendedKeyUsagePurpose::CodeSigning)] {
        let chain = TestChain::with(ChainOptions {
            leaf_eku: eku.clone(),
            ..ChainOptions::default()
        });
        let receipt = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.relay.monthly", 30));
        assert_eq!(
            chain.verifier(true).verify(&receipt),
            Ok(Plan::Relay),
            "a leaf with {eku:?} should verify either way"
        );
    }
}

/// The developer-certificate case, and the reason the marker check exists: a certificate Apple
/// issued to someone, signed by an intermediate that chains to the pinned root, carrying a key its
/// owner controls. Everything about this receipt is genuine except that it is not a purchase.
#[test]
fn a_certificate_apple_issued_to_someone_else_is_not_a_purchase() {
    let chain = TestChain::with(ChainOptions {
        leaf_marker: false,
        ..ChainOptions::default()
    });
    let receipt = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    assert_eq!(
        chain.verifier(true).verify(&receipt),
        Err(Rejection::NotAnAppStoreCertificate)
    );
}

/// The same check on the other certificate: the leaf looks right, but nothing in the chain is
/// Apple's issuing authority.
#[test]
fn a_chain_without_apples_intermediate_is_not_a_purchase() {
    let chain = TestChain::with(ChainOptions {
        intermediate_marker: false,
        ..ChainOptions::default()
    });
    let receipt = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    assert_eq!(
        chain.verifier(true).verify(&receipt),
        Err(Rejection::NotAnAppStoreCertificate)
    );
}

/// The intermediate that is checked is the one that signed the leaf, not whichever entry of `x5c`
/// happens to carry Apple's marker. A receipt can attach any certificate it likes to its header,
/// and Apple's intermediates are public: a check that searched the list would accept a chain whose
/// real issuer carries nothing, with Apple's certificate pasted in beside it as decoration.
#[test]
fn a_pasted_in_marker_certificate_does_not_stand_in_for_the_issuer() {
    let chain = TestChain::with(ChainOptions {
        intermediate_marker: false,
        ..ChainOptions::default()
    });
    // A second chain's intermediate: a certificate that does carry the marker, and is not the one
    // that signed anything here.
    let decoy = TestChain::genesis();

    let mut x5c = chain.x5c();
    x5c.insert(1, base64(decoy.intermediate.as_ref()));

    let header = serde_json::json!({ "alg": "ES256", "x5c": x5c });
    let receipt = chain.jws_with(&header, &transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    assert_eq!(
        chain.verifier(true).verify(&receipt),
        Err(Rejection::NotAnAppStoreCertificate)
    );
}

/// The pinned root itself, sent as the leaf. It chains to the anchor trivially — it *is* the
/// anchor, and the client holds its public key in the receipt — so this is the one chain a client
/// can assemble without any secret at all, and it has to buy nothing.
///
/// It is refused for being a certificate authority rather than for being the wrong certificate:
/// `webpki` will not use a CA certificate as an end entity, which is the first of the two reasons
/// this fails. The marker check below it is the second, and it is the one that matters for a
/// certificate that is *not* a CA — see the developer-certificate test.
#[test]
fn the_pinned_root_cannot_be_its_own_signing_certificate() {
    let chain = TestChain::genesis();
    let header = serde_json::json!({
        "alg": "ES256",
        "x5c": [base64(chain.root.as_ref())],
    });
    let receipt = chain.jws_with(&header, &transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    assert_eq!(
        chain.verifier(true).verify(&receipt),
        Err(Rejection::UntrustedChain)
    );
}

/// A chain with the middle taken out. The leaf's issuer is not in it, so it cannot reach the root,
/// and the failure is the chain rather than anything the client wrote.
#[test]
fn a_truncated_chain_cannot_reach_the_root() {
    let chain = TestChain::genesis();
    let header = serde_json::json!({
        "alg": "ES256",
        "x5c": [base64(chain.leaf.as_ref()), base64(chain.root.as_ref())],
    });
    let receipt = chain.jws_with(&header, &transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    assert_eq!(
        chain.verifier(true).verify(&receipt),
        Err(Rejection::UntrustedChain)
    );

    // And nothing at all where the chain should be is refused before anything is parsed.
    let header = serde_json::json!({ "alg": "ES256" });
    let receipt = chain.jws_with(&header, &transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));
    assert_eq!(
        chain.verifier(true).verify(&receipt),
        Err(Rejection::BadCertificateChain)
    );
}

/// Expiry is checked twice and both are real: the certificates have dates and so does the
/// subscription. This is the second one — a chain that is valid today whose product ran out.
#[test]
fn a_subscription_that_has_run_out_buys_nothing() {
    let chain = TestChain::genesis();
    let relay = chain.verifier(true);

    let receipt = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", -1));
    assert_eq!(relay.verify(&receipt), Err(Rejection::Expired));

    // The edge: a receipt that expires this second is out, because the check is `>` and a
    // subscription is over when it is over.
    let header = chain.header();
    let payload = format!(
        r#"{{"bundleId":"{APP_BUNDLE_ID}","productId":"pl.dmq.peering.iap.pro.year","expiresDate":{}}}"#,
        support::now_millis()
    );
    assert_eq!(
        relay.verify(&chain.jws_with(&header, &payload)),
        Err(Rejection::Expired)
    );
}

/// The first expiry check: certificates that were valid once and are not now. This is a chain the
/// test generated and then aged, so it proves the dates are read rather than that Apple's are.
#[test]
fn a_lapsed_chain_buys_nothing() {
    let chain = TestChain::with(ChainOptions {
        lapsed: true,
        ..ChainOptions::default()
    });
    let receipt = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    assert_eq!(chain.verifier(true).verify(&receipt), Err(Rejection::UntrustedChain));
}

/// A refund, which Apple stamps on the transaction rather than taking out of the chain.
#[test]
fn a_revoked_transaction_buys_nothing() {
    let chain = TestChain::genesis();
    let receipt = chain.jws(&revoked_transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year"));

    assert_eq!(
        chain.verifier(true).verify(&receipt),
        Err(Rejection::Revoked)
    );
}

/// A sandbox purchase is signed by Apple, names the real product and carries a real expiry, and it
/// is free to anyone a developer account can hand a sandbox login to. Believing it would put the
/// price of unlimited relay at one App Store Connect login, so it is refused — at the cost of
/// TestFlight and sandbox testers, who are on the claimed plan for as long as the fallback is on.
#[test]
fn a_sandbox_purchase_is_not_a_purchase() {
    let chain = TestChain::genesis();
    let receipt = chain.jws(&sandbox_transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year"));

    assert_eq!(
        chain.verifier(true).verify(&receipt),
        Err(Rejection::NotARealPurchase)
    );
}

/// The other side of that check: what it must not refuse. A payload with no `environment` is what a
/// producer that predates the field sends, and the check is a denial list for exactly this reason —
/// refusing an environment this module has not seen before would meter a subscriber as free.
#[test]
fn a_purchase_with_no_environment_field_is_still_a_purchase() {
    let chain = TestChain::genesis();
    let receipt = chain
        .jws(&environmentless_transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year"));

    assert_eq!(chain.verifier(true).verify(&receipt), Ok(Plan::Pro));
}

// MARK: - The payload

#[test]
fn a_receipt_for_another_app_buys_nothing() {
    let chain = TestChain::genesis();
    for bundle in ["pl.dmq.peering.other", "com.example.peering", ""] {
        let receipt = chain.jws(&transaction(bundle, "pl.dmq.peering.iap.pro.year", 30));
        assert_eq!(
            chain.verifier(true).verify(&receipt),
            Err(Rejection::WrongBundle),
            "{bundle:?} is not this app"
        );
    }
}

#[test]
fn a_product_this_app_does_not_sell_buys_nothing() {
    let chain = TestChain::genesis();
    for product in ["pl.dmq.peering.iap.relay.weekly", "pl.dmq.peering.iap.plus.year", "pro", ""] {
        let receipt = chain.jws(&transaction(APP_BUNDLE_ID, product, 30));
        assert_eq!(
            chain.verifier(true).verify(&receipt),
            Err(Rejection::UnknownProduct),
            "{product:?} is not a product of this app"
        );
    }
}

/// A payload with no expiry is not a subscription, and the verifier says so rather than treating
/// the absence as "never expires".
#[test]
fn a_transaction_with_no_expiry_buys_nothing() {
    let chain = TestChain::genesis();
    let payload = format!(
        r#"{{"bundleId":"{APP_BUNDLE_ID}","productId":"pl.dmq.peering.iap.pro.year"}}"#
    );
    assert_eq!(
        chain.verifier(true).verify(&chain.jws(&payload)),
        Err(Rejection::NoExpiry)
    );

    // Nor is a payload that is not a transaction at all.
    assert_eq!(
        chain.verifier(true).verify(&chain.jws("{}")),
        Err(Rejection::BadPayload)
    );
    assert_eq!(
        chain.verifier(true).verify(&chain.jws("not json")),
        Err(Rejection::BadPayload)
    );
}

// MARK: - The signature

/// The one an attacker reaches for first: change the product in the payload and send it on with
/// the signature that was over the old one.
#[test]
fn a_tampered_payload_does_not_verify() {
    let chain = TestChain::genesis();
    let honest = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.relay.monthly", 30));

    let segments: Vec<&str> = honest.split('.').collect();
    let forged_payload = base64(transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30).as_bytes());
    let forged = format!("{}.{}.{}", segments[0], forged_payload, segments[2]);

    assert_eq!(
        chain.verifier(true).verify(&forged),
        Err(Rejection::BadSignature)
    );
}

/// The signature covers the text of the first two segments, not the values they decode to. A header
/// spelled with different whitespace is the same header and a different document, and it does not
/// verify — which is what proves the relay verifies what it was sent rather than a normalised
/// re-encoding of it.
#[test]
fn a_header_spelled_differently_does_not_verify() {
    let chain = TestChain::genesis();
    let header = chain.header();
    let honest = chain.jws_with(&header, &transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));
    let segments: Vec<&str> = honest.split('.').collect();

    // The same header object, serialised with the whitespace pretty-printing adds.
    let respelled = base64_url(&serde_json::to_vec_pretty(&header).expect("header encodes"));
    let forged = format!("{respelled}.{}.{}", segments[1], segments[2]);

    assert_eq!(
        chain.verifier(true).verify(&forged),
        Err(Rejection::BadSignature)
    );
}

/// A signature by the right key over the wrong bytes, which is what a client that signs its own
/// transaction would produce.
#[test]
fn a_signature_over_other_bytes_does_not_verify() {
    let chain = TestChain::genesis();
    let honest = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));
    let segments: Vec<&str> = honest.split('.').collect();

    // Valid ES256 over text of the same shape, made by the same key, about a different document.
    let signature = chain.sign("a-different-document-entirely");
    let forged = format!("{}.{}.{}", segments[0], segments[1], signature);

    assert_eq!(
        chain.verifier(true).verify(&forged),
        Err(Rejection::BadSignature)
    );
}

// MARK: - The algorithm

/// `none` is the algorithm that means "no signature", and the only acceptable answer to it is
/// refusal. So is every other algorithm the header could name, since the relay reads ES256 only.
#[test]
fn only_es256_is_read() {
    let chain = TestChain::genesis();
    let payload = transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30);

    for alg in ["none", "None", "HS256", "ES384", "RS256", ""] {
        let header = serde_json::json!({ "alg": alg, "x5c": chain.x5c() });
        let receipt = chain.jws_with(&header, &payload);
        assert_eq!(
            chain.verifier(true).verify(&receipt),
            Err(Rejection::UnsupportedAlgorithm),
            "alg {alg:?} should not be read"
        );
    }

    // And the unsigned spelling of `none`, which is a JWS with an empty signature rather than one
    // with a header: two segments and a trailing dot.
    let unsigned = format!(
        "{}.{}.",
        base64(br#"{"alg":"none","x5c":[]}"#),
        base64(payload.as_bytes())
    );
    assert_eq!(
        chain.verifier(true).verify(&unsigned),
        Err(Rejection::UnsupportedAlgorithm)
    );
}

// MARK: - Size

/// The receipt has to fit, and the limit has to be roomier than a real one — the failure on the
/// wrong side of that is a subscriber metered as free.
#[test]
fn a_receipt_is_small_enough_to_travel_in_the_handshake() {
    let chain = TestChain::genesis();
    let receipt = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    assert!(
        receipt.len() < MAX_JWS_BYTES,
        "a receipt of {} bytes should fit in {MAX_JWS_BYTES}",
        receipt.len()
    );
    assert!(
        receipt.len() < 16 * 1024,
        "and it has to fit in a WebSocket frame the signalling socket will read"
    );

    // One byte over is refused before anything is parsed, rather than being read and rejected for
    // a reason that depends on its contents.
    let oversize = "a".repeat(MAX_JWS_BYTES + 1);
    assert_eq!(
        chain.verifier(true).verify(&oversize),
        Err(Rejection::TooLarge)
    );
}

// MARK: - The fallback

/// The transition, stated as a table. Every one of these is a client the relay currently has:
/// one that sends nothing, one that sends a receipt that does not verify, and one that sends a
/// receipt that does.
#[test]
fn an_unproven_client_is_metered_by_what_it_claims_until_it_is_not() {
    let chain = TestChain::genesis();
    let forged = TestChain::genesis().jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));
    let genuine = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    let trusting = chain.verifier(true);
    let strict = chain.verifier(false);

    // Nothing sent: the shipped app, and the reason the fallback exists.
    let resolved = trusting.resolve(Plan::Pro, None);
    assert_eq!(resolved.plan, Plan::Pro);
    assert_eq!(resolved.trust, Trust::Claimed);
    assert_eq!(resolved.rejected, None);

    // A receipt that does not verify leaves the client exactly where sending nothing would, and
    // the reason travels with it so an operator can see the receipts that would fail.
    let resolved = trusting.resolve(Plan::Pro, Some(strict.verify(&forged)));
    assert_eq!(resolved.plan, Plan::Pro);
    assert_eq!(resolved.trust, Trust::Claimed);
    assert_eq!(resolved.rejected, Some(Rejection::UntrustedChain));

    // The same two clients with the fallback off, which is what closing the hole looks like.
    for claimed in [Plan::Relay, Plan::Pro] {
        let resolved = strict.resolve(claimed, None);
        assert_eq!(resolved.plan, Plan::Free);
        assert_eq!(resolved.trust, Trust::None);
    }

    // And the one thing neither switch touches: a receipt that verifies.
    let resolved = strict.resolve(Plan::Free, Some(strict.verify(&genuine)));
    assert_eq!(resolved.plan, Plan::Pro);
    assert_eq!(resolved.trust, Trust::Verified);
}

// MARK: - Through the handshake

/// A relay with a verifier pinned to the test chain's root, and a free allowance that is already
/// spent, so the plan in the answer is the only thing that can decide whether a client connects.
async fn relay(verifier: StoreKitVerifier) -> u16 {
    let registry = Arc::new(Registry::new(usize::MAX));
    let signal = TcpListener::bind("127.0.0.1:0").await.expect("should bind");
    let port = signal.local_addr().expect("should have an address").port();

    let quota = Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default()));
    // Spent rather than configured away, so the test travels the path a client does: a whole free
    // allowance already used, which is where a subscriber on the free plan would be.
    quota.record("phone", Duration::from_secs(30 * 60 + 1));

    tokio::spawn(signalling::serve(
        signal,
        registry,
        HostRegistry::new(),
        Settings {
            host: Some("127.0.0.1".into()),
            public_control_port: 9443,
            // Signaling only in this test: what a client pays for never reaches the video socket,
            // so the port is a number and nothing here binds it.
            video_port: 30190,
            session_ttl: Duration::from_secs(60),
            quota,
            receipts: Arc::new(verifier),
            // No ceiling in these tests, and no timeouts short enough to interfere with them: they
            // are about what the relay does with a session, not about what it refuses. Both have
            // their own tests.
            max_sessions: usize::MAX,
            max_connections: 1 << 20,
            handshake_timeout: Duration::from_secs(10),
            idle_timeout: Duration::from_secs(90),
            apns: None,
            fcm: None,
            play: None,
            limiter: Arc::new(peeringd::limits::PeerLimiter::default()),
            require_proven_hosts: false,
        },
        None,
    ));

    port
}

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(port: u16) -> Ws {
    let (ws, _) = timeout(
        PATIENCE,
        tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}")),
    )
    .await
    .expect("the signalling socket should open")
    .expect("the websocket handshake should succeed");
    ws
}

async fn send(ws: &mut Ws, message: &ClientMessage) {
    let json = serde_json::to_string(message).expect("should encode");
    ws.send(Message::Text(json.into())).await.expect("should send");
}

async fn next_message(ws: &mut Ws) -> ServerMessage {
    loop {
        let message = timeout(PATIENCE, ws.next())
            .await
            .expect("timed out waiting for a message")
            .expect("the stream ended early")
            .expect("the websocket errored");
        if let Message::Text(text) = message {
            return serde_json::from_str(&text).expect("should parse as ServerMessage");
        }
    }
}

/// Registers a Mac and waits for the acknowledgement, so it is not tripped over by a later read.
async fn register_mac(port: u16) -> Ws {
    let mut mac = connect(port).await;
    send(
        &mut mac,
        &ClientMessage::RegisterHost {
            device_id: "mac".into(),
            name: "Studio".into(),
            protocol_version: 3,
            public_key: None,
            proof: None,
            proof_time: None,
        },
    )
    .await;
    assert!(matches!(
        next_message(&mut mac).await,
        ServerMessage::Registered { .. }
    ));
    mac
}

/// Asks for the Mac with a plan and a receipt, and reports what the relay decided.
async fn ask(port: u16, plan: &str, jws: Option<String>) -> ServerMessage {
    let _mac = register_mac(port).await;
    let mut phone = connect(port).await;
    send(
        &mut phone,
        &ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
            api_key: None,
            plan: Some(plan.into()),
            jws_representation: jws,
            public_key: None,
            proof: None,
            proof_time: None,
            play_purchase_token: None,
            play_product_id: None,
        },
    )
    .await;
    next_message(&mut phone).await
}

/// The whole change, end to end: the same client, past its free allowance, is refused when it
/// claims `pro` and connected when it proves it. Only the receipt is different.
#[tokio::test]
async fn a_verified_receipt_is_what_buys_the_allowance() {
    let chain = TestChain::genesis();
    let port = relay(chain.verifier(true)).await;
    let receipt = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    let without = ask(port, "free", None).await;
    assert!(
        matches!(without, ServerMessage::Error { ref code, .. } if code == "quotaExceeded"),
        "a client with no receipt is metered as free: {without:?}"
    );

    let with = ask(port, "free", Some(receipt)).await;
    assert!(
        matches!(with, ServerMessage::SessionReady { .. }),
        "the same client with a receipt Apple signed has the unlimited plan: {with:?}"
    );
}

/// The hole, in a test that will start failing the day it is closed. With the fallback on, a
/// receipt that does not verify is worth exactly what the claim is worth, which is the point of
/// the fallback and also the reason it has to go.
#[tokio::test]
async fn a_receipt_that_does_not_verify_leaves_the_claim_standing() {
    let forged = TestChain::genesis().jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    let trusting = relay(TestChain::genesis().verifier(true)).await;
    let answer = ask(trusting, "pro", Some(forged.clone())).await;
    assert!(
        matches!(answer, ServerMessage::SessionReady { .. }),
        "the claim is still believed while the fallback is on: {answer:?}"
    );

    // The same request against a relay that does not trust claims: the subscription is invisible
    // to the relay and the client is back to the free allowance, which is what closing it looks
    // like from the client's side.
    let strict = relay(TestChain::genesis().verifier(false)).await;
    let answer = ask(strict, "pro", Some(forged)).await;
    assert!(
        matches!(answer, ServerMessage::Error { ref code, .. } if code == "quotaExceeded"),
        "with the fallback off, an unproven plan is the free allowance: {answer:?}"
    );
}

/// A receipt is not a licence to skip the rest of the handshake: a client on the unlimited plan
/// still cannot reach a Mac that is not there.
#[tokio::test]
async fn a_receipt_does_not_make_a_mac_appear() {
    let chain = TestChain::genesis();
    let port = relay(chain.verifier(true)).await;
    let receipt = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.pro.year", 30));

    let mut phone = connect(port).await;
    send(
        &mut phone,
        &ClientMessage::ConnectToHost {
            host_id: "nobody".into(),
            client_id: "phone".into(),
            protocol_version: 3,
            api_key: None,
            plan: Some("pro".into()),
            jws_representation: Some(receipt),
            public_key: None,
            proof: None,
            proof_time: None,
            play_purchase_token: None,
            play_product_id: None,
        },
    )
    .await;

    assert_eq!(
        next_message(&mut phone).await,
        ServerMessage::HostOffline {
            device_id: "nobody".into()
        }
    );
}

/// A receipt repeated on one socket is answered the same way, and the second request is answered at
/// all rather than refused. What this pins is the behaviour rather than the cost: how many times the
/// relay verified is not observable from outside the process, and is covered by
/// `storekit::tests::one_session_can_only_have_so_many_receipts_verified` instead.
#[tokio::test]
async fn a_receipt_repeated_on_one_socket_is_answered_the_same_way() {
    let chain = TestChain::genesis();
    let port = relay(chain.verifier(true)).await;
    let receipt = chain.jws(&transaction(APP_BUNDLE_ID, "pl.dmq.peering.iap.relay.monthly", 30));

    let _mac = register_mac(port).await;
    let mut phone = connect(port).await;
    for _ in 0..2 {
        send(
            &mut phone,
            &ClientMessage::ConnectToHost {
                host_id: "mac".into(),
                client_id: "phone".into(),
                protocol_version: 3,
                api_key: None,
                plan: Some("free".into()),
                jws_representation: Some(receipt.clone()),
                public_key: None,
                proof: None,
                proof_time: None,
                play_purchase_token: None,
                play_product_id: None,
            },
        )
        .await;
        assert!(
            matches!(next_message(&mut phone).await, ServerMessage::SessionReady { .. }),
            "the Relay plan should be there both times"
        );
    }
}

/// The chain a test generates has to have the shape Apple's has, or the tests above are proving
/// something about a fixture rather than about receipts: three certificates, leaf first and the
/// pinned root last, which is the order Apple's own documentation describes.
#[test]
fn the_generated_chain_has_apples_shape() {
    let chain = TestChain::genesis();
    let x5c = chain.x5c();
    assert_eq!(x5c.len(), 3, "Apple sends leaf, intermediate, root");
    assert_eq!(x5c[0], base64(chain.leaf.as_ref()), "position 0 is the leaf");
    assert_eq!(
        x5c[1],
        base64(chain.intermediate.as_ref()),
        "position 1 is the intermediate"
    );
    assert_eq!(x5c[2], base64(chain.root.as_ref()), "position 2 is the root");
}
