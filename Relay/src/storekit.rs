//! App Store receipts: whether the plan a client is on is one Apple signed for, or only one the
//! client says it bought.
//!
//! `quota.rs` says what each plan allows. This module decides which plan a client *is* on, and it
//! exists because until now the relay decided that from the client's own word: `ConnectToHost`
//! carried a plan name and the relay metered by it, so a patched app could say `pro` and relay for
//! free forever. The proof that closes that is a document only Apple can produce — the JWS StoreKit
//! hands the app for its transaction (`Transaction.jwsRepresentation`), which names the product the
//! user actually bought and carries Apple's signature over it.
//!
//! **What is checked, in order.** The JWS is a compact ES256 JWS. Its header names a certificate
//! chain in `x5c`; the chain is validated up to the pinned root in `AppleRootCA-G3.cer`, using
//! `rustls-webpki` for the path, the signature on every link, and the validity dates. The leaf and
//! the intermediate must then carry Apple's own marker extensions, which is the check Apple's
//! App Store Server Library performs on both (`1.2.840.113635.100.6.11.1` on the signing
//! certificate, `1.2.840.113635.100.6.2.1` on the intermediate) and the only thing separating an
//! App Store signing certificate from any other certificate Apple has issued to someone. The JWS
//! signature itself is then verified with the leaf's key. Only then is the payload read: this app's
//! `bundleId`, one of the three products, a future `expiresDate`, no `revocationDate`, and an
//! `environment` that is not one of the two Apple signs for testing rather than for buying.
//!
//! **Everything else is the free plan.** Absent, malformed, oversized, expired, revoked, a chain
//! that does not reach the pinned root, a certificate that is not Apple's, a product this app does
//! not sell, a sandbox purchase: every one of those ends at the free allowance rather than at a
//! refusal, because a client that cannot prove what it bought is exactly the client the free
//! allowance is for.
//!
//! **A claimed plan buys nothing on its own, and that is the default.** A client that sends
//! `"plan":"pro"` with no receipt is metered as a client that bought nothing, which is the answer
//! to the money hole this module was written for: a patched app can still say `pro`, and all it
//! gets for saying it is the free allowance. The claim is not thrown away, though: every session
//! line says which path decided the plan, so a support question about a client that should be
//! paying is answered by the log rather than by a guess. Three words carry the whole of it:
//!
//! * `verified`: Apple signed the receipt, and the plan is the product it named.
//! * `claimed`: nothing was proven and the operator has opened the switch below, so the client's
//!   word decided.
//! * `neither`: nothing was proven, so the free allowance.
//!
//! **`PEERINGD_TRUST_CLAIMED_PLANS=1` re-opens the hole, and it exists for beta testing.** A
//! TestFlight build's receipt is a sandbox one, and this module refuses those by name
//! (`not_a_real_purchase`): Apple signs them and they name the real products, but they are handed
//! out for nothing to anyone with a developer account, so believing one would put the price of
//! unlimited relay at an App Store Connect login. A tester who has bought the real thing is
//! therefore metered as free on a beta build, the free allowance on a phone that says `pro`, and
//! the switch is what an operator sets so that the people testing a build are metered by what they
//! claim. Every other client gets its plan from the same switch while it is on, which is the trade,
//! and startup says which state the relay is in.
//!
//! **The switch is also the way back**, which is worth knowing before shipping this: nothing here
//! has been run against a receipt Apple actually signed, so if verification turns out to refuse
//! them, opening the switch returns the relay to metering by the claim on the next restart, with no
//! new build.
//!
//! The one outcome that must be impossible is an unproven client being metered as unlimited with
//! the switch closed, and `tests/storekit.rs` is organised around it: every refusal is a test, and
//! each one changes a single thing about a chain that would otherwise verify. What the fallback
//! below then does with the same client is a different decision, and the tests that pin it are
//! named for the hole they describe rather than for an outcome anybody wants.
//!
//! **The JWS is never logged.** It is a few kilobytes of base64 that identify a purchase, it
//! arrives once per session, and a log is the wrong place for it. What is logged is the verdict:
//! the plan, the path, and the reason a receipt was refused.
//!
//! **No network.** Verification is offline against a root that ships inside the binary, which is
//! what keeps the relay's promise that there is no account to ask about and no database to leak.
//! Apple publishes no CRL for these certificates, so revocation is read from the receipt's own
//! `revocationDate` rather than from a list.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig};
use rustls_pki_types::{CertificateDer, SignatureVerificationAlgorithm, UnixTime};
use serde::Deserialize;
use tracing::warn;
use webpki::{EndEntityCert, ExtendedKeyUsageValidator, KeyPurposeIdIter};
use x509_cert::der::Decode as _;
use x509_cert::der::asn1::ObjectIdentifier;

use crate::quota::Plan;

/// Apple Root CA - G3, DER, downloaded over HTTPS from Apple's certificate authority page
/// (<https://www.apple.com/certificateauthority/AppleRootCA-G3.cer>) and embedded in the binary so
/// that no deployment can be missing it or swap it.
///
/// **This is the whole of the trust.** It is the root Apple signs App Store Server API
/// transactions and the App Store's own JWS documents with, and pinning it is what makes the chain
/// in a client's header worth reading: a chain is a claim by whoever sent it, and this is the one
/// link in it that did not come from the client.
///
/// **Where it came from is the download, not a test.** Nothing in this repository can establish
/// that this file is Apple's root — that is what fetching it from Apple over TLS was for — and the
/// fingerprint below is a record of which file was fetched rather than a second opinion about it.
/// What the fingerprint does buy is the thing a pin is for: a file that has been corrupted or
/// swapped for another stops a test and every receipt with it, instead of quietly anchoring the
/// relay to somebody else's certificate.
const APPLE_ROOT_CA_G3: &[u8] = include_bytes!("AppleRootCA-G3.cer");

/// SHA-256 of the file above, as `shasum -a 256` printed it for the download.
///
/// Here as a constant rather than computed at run time, because a hash computed next to the thing
/// it hashes says only that the file has not changed since the process started, where a
/// written-down one says which file this is supposed to be.
pub const APPLE_ROOT_CA_G3_SHA256: [u8; 32] = [
    0x63, 0x34, 0x3a, 0xbf, 0xb8, 0x9a, 0x6a, 0x03, 0xeb, 0xb5, 0x7e, 0x9b, 0x3f, 0x5f, 0xa7, 0xbe,
    0x7c, 0x4f, 0x5c, 0x75, 0x6f, 0x30, 0x17, 0xb3, 0xa8, 0xc4, 0x88, 0xc3, 0x65, 0x3e, 0x91, 0x79,
];

/// This app's bundle identifier, which the receipt must name.
///
/// **The same string as `PRODUCT_BUNDLE_IDENTIFIER`** in `MacCast.xcodeproj`, and the same string
/// the receipt's `bundleId` carries. A receipt for another app is a real receipt that proves
/// nothing about this one, so it is refused; a fork of this repository that renames the app must
/// change this line, and there is nowhere else it appears.
pub const APP_BUNDLE_ID: &str = "pl.dmq.peering";

/// The products this app sells, and the plan each one buys.
///
/// **The product identifiers are the app's, repeated here.** `StoreManager.monthlyID`, `plusID` and
/// `yearID` in `MacCast/StoreManager.swift` hold the authority, and `Tier.plan` maps the same three
/// products to the same three names. Edit one without the others and a paying subscriber is metered
/// as free — which is the direction this table is allowed to fail in, and the reason an unknown
/// product is the free allowance rather than a refusal.
const PRODUCTS: &[(&str, Plan)] = &[
    ("pl.dmq.peering.relay.monthly", Plan::Relay),
    ("pl.dmq.peering.relayplus.monthly", Plan::Plus),
    ("pl.dmq.peering.relay.year", Plan::Pro),
];

/// Apple's marker extension on a signing certificate, from the Apple WWDR Certificate Practice
/// Statement (section 4.11.10, Mac App Store Receipt Signing Certificates) and from the
/// `SignedDataVerifier` in Apple's own App Store Server Library, which requires it on the leaf.
///
/// **This is what tells Apple's signing certificate apart from every other certificate Apple has
/// issued.** Anyone with a developer account holds an Apple-signed certificate, and its key can
/// sign a JWS whose chain reaches the same root; the marker is in a certificate only Apple's
/// receipt-signing authority issues, so its absence is the difference between a purchase and a
/// developer certificate used as one.
const LEAF_MARKER: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113635.100.6.11.1");

/// Apple's marker extension on the intermediate that issues those certificates, required on the
/// intermediate for the same reason and checked by the same library.
const INTERMEDIATE_MARKER: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("1.2.840.113635.100.6.2.1");

/// The longest receipt the relay will read.
///
/// A real one is around five kilobytes and almost all of it is the three certificates in `x5c`,
/// which are fixed-size for years at a time. Sixteen kilobytes is room for Apple to add an
/// intermediate or grow a key without a client being metered as free by an arithmetic accident, and
/// it is well inside the 64 KB the signalling socket already refuses to read past. Anything longer
/// is refused before it is parsed, so an oversized message costs one length comparison.
pub const MAX_JWS_BYTES: usize = 16 * 1024;

/// How each link of the chain may be signed.
///
/// The leaf and the JWS are ES256 and are checked as such, but the links above the leaf are Apple's
/// business: the G3 root's key is P-384, its intermediate is signed with SHA-384, and Apple can
/// reissue either without telling this relay. Naming only ES256 here would refuse a real receipt the
/// day the intermediate changed, so every algorithm the root could plausibly use is allowed. It
/// costs nothing to allow them: a chain has to reach the pinned root either way, and no signature
/// algorithm makes a certificate signed by someone else's key into one signed by Apple's.
const CHAIN_ALGORITHMS: &[&dyn SignatureVerificationAlgorithm] = &[
    webpki::ring::ECDSA_P256_SHA256,
    webpki::ring::ECDSA_P256_SHA384,
    webpki::ring::ECDSA_P384_SHA256,
    webpki::ring::ECDSA_P384_SHA384,
    webpki::ring::RSA_PKCS1_2048_8192_SHA256,
    webpki::ring::RSA_PKCS1_2048_8192_SHA384,
    webpki::ring::RSA_PKCS1_2048_8192_SHA512,
];

/// Standard base64, because `x5c` holds DER rather than a JWS segment, and indifferent to padding
/// so that a chain which arrived without it is read rather than thrown away.
const CERT_BASE64: GeneralPurpose = GeneralPurpose::new(
    &base64::alphabet::STANDARD,
    GeneralPurposeConfig::new()
        .with_decode_padding_mode(base64::engine::DecodePaddingMode::Indifferent),
);

/// base64url, for the three segments of the JWS itself. Indifferent to padding for the same reason:
/// padding is not part of what the signature covers in any way a producer could exploit, since
/// changing the text of a segment changes what was signed and the signature then fails.
const SEGMENT_BASE64: GeneralPurpose = GeneralPurpose::new(
    &base64::alphabet::URL_SAFE,
    GeneralPurposeConfig::new()
        .with_decode_padding_mode(base64::engine::DecodePaddingMode::Indifferent),
);

/// Accepts any extended key usage, and this is a decision rather than an omission.
///
/// `webpki` wants to be told which EKU the end-entity certificate must carry, and there is no OID
/// that can honestly be named here. Apple's own App Store Server Library does not check the EKU
/// either: it checks the two marker extensions above, which is the check that actually distinguishes
/// a receipt-signing certificate. Guessing an EKU OID and getting it wrong would meter every
/// subscriber as free on the day this deployed, which is the failure this module exists to remove
/// rather than to reintroduce. The purpose of the certificate is settled by `LEAF_MARKER`, which is
/// Apple's own answer to the same question.
struct AnyPurpose;

impl ExtendedKeyUsageValidator for AnyPurpose {
    fn validate(&self, _purposes: KeyPurposeIdIter<'_, '_>) -> Result<(), webpki::Error> {
        Ok(())
    }
}

/// Which of the two paths decided a plan, for the log line and for the tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trust {
    /// Apple signed it: the plan came from a product identifier in a verified receipt.
    Verified,
    /// No receipt, or one that did not verify, so the plan is the client's own statement.
    Claimed,
    /// Nothing readable at all, so the free allowance.
    None,
}

impl Trust {
    /// The word that goes in the log, and the one an operator greps for when asking whether the
    /// paying clients are being recognised. Three spellings rather than a boolean, because the
    /// question a session line answers is not "was this plan proven" but "was it proven, claimed,
    /// or neither".
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Verified => "verified",
            Self::Claimed => "claimed",
            Self::None => "neither",
        }
    }
}

/// The plan to meter by, how the relay came to it, and — when a receipt was sent and refused — why.
///
/// The reason is carried rather than logged where it is found so that the session line, which is
/// the line an operator reads, can say all of it at once. `None` means no receipt was sent at all,
/// which is not a rejection: it is a client with nothing to prove, and it is what the free
/// allowance is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Resolved {
    pub plan: Plan,
    pub trust: Trust,
    pub rejected: Option<Rejection>,
}

/// Why a receipt bought nothing. Every one of these ends at the free allowance, and the strings are
/// the log's vocabulary rather than prose, because the prose a user reads belongs to the app.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rejection {
    /// Empty, or not three dot-separated segments.
    Malformed,
    /// Longer than `MAX_JWS_BYTES`.
    TooLarge,
    /// A segment that is not base64url, or a header that is not a JSON object.
    BadEncoding,
    /// `alg` is anything but ES256, including `none`.
    UnsupportedAlgorithm,
    /// No `x5c`, or a certificate that is not DER.
    BadCertificateChain,
    /// The chain does not end at the pinned root, or a certificate in it is outside its dates.
    UntrustedChain,
    /// A certificate that is not one of Apple's receipt-signing certificates.
    NotAnAppStoreCertificate,
    /// The signature is not the leaf key's over the first two segments.
    BadSignature,
    /// The payload is not a JSON object with the fields a transaction has.
    BadPayload,
    /// A receipt for a different app.
    WrongBundle,
    /// A product this app does not sell.
    UnknownProduct,
    /// There is no expiry, so this is not a subscription.
    NoExpiry,
    /// The subscription has run out.
    Expired,
    /// Apple marked the transaction revoked.
    Revoked,
    /// A transaction Apple signed for testing rather than for buying: a sandbox purchase, or one of
    /// Xcode's own. The one an operator meets first is a TestFlight build's, which is signed, names
    /// the real product and is refused here all the same.
    NotARealPurchase,
    /// One session sent more distinct receipts than it is allowed to have verified.
    TooManyReceipts,
}

impl Rejection {
    /// The word for the log. Stable, lowercase, and safe to grep for.
    pub fn reason(self) -> &'static str {
        match self {
            Self::Malformed => "malformed",
            Self::TooLarge => "too_large",
            Self::BadEncoding => "bad_encoding",
            Self::UnsupportedAlgorithm => "unsupported_algorithm",
            Self::BadCertificateChain => "bad_certificate_chain",
            Self::UntrustedChain => "untrusted_chain",
            Self::NotAnAppStoreCertificate => "not_an_app_store_certificate",
            Self::BadSignature => "bad_signature",
            Self::BadPayload => "bad_payload",
            Self::WrongBundle => "wrong_bundle",
            Self::UnknownProduct => "unknown_product",
            Self::NoExpiry => "no_expiry",
            Self::Expired => "expired",
            Self::Revoked => "revoked",
            Self::NotARealPurchase => "not_a_real_purchase",
            Self::TooManyReceipts => "too_many_receipts",
        }
    }
}

/// Decides whether a receipt is Apple's, and what it buys.
///
/// Constructed once at startup and shared: the pinned root is parsed per verification rather than
/// held parsed, because the self-referential borrow that holding it would need is worse than the
/// microseconds it costs to read 583 bytes once per session.
pub struct StoreKitVerifier {
    root: Vec<u8>,
    bundle_id: String,
    /// Whether a plan the client claims is believed when there is no verified receipt.
    ///
    /// **False is the shipped behaviour**, and the only thing true buys is more relay time than
    /// anyone can prove a right to: see the module comment for what it is for and what it costs.
    trust_claims: bool,
}

impl StoreKitVerifier {
    pub fn new(root_der: impl Into<Vec<u8>>, bundle_id: impl Into<String>, trust_claims: bool) -> Self {
        Self {
            root: root_der.into(),
            bundle_id: bundle_id.into(),
            trust_claims,
        }
    }

    /// The relay's own verifier: Apple's root, this app's bundle, and the fallback as configured.
    pub fn apple(trust_claims: bool) -> Self {
        Self::new(APPLE_ROOT_CA_G3, APP_BUNDLE_ID, trust_claims)
    }

    /// Whether the claimed plan is believed when no receipt verified.
    ///
    /// Read at startup, so that what the operator is told about the hole is about the verifier that
    /// was actually built rather than about the configuration it was built from.
    pub fn trusts_claims(&self) -> bool {
        self.trust_claims
    }

    /// The plan this receipt entitles its holder to, or why it entitles them to nothing.
    ///
    /// The clock is read here rather than passed in because nothing in the relay wants to verify a
    /// receipt at a time other than now; `verify_at` exists for the tests, where "now" is the only
    /// way to test an expiry without waiting for one.
    pub fn verify(&self, jws: &str) -> Result<Plan, Rejection> {
        self.verify_at(jws, SystemTime::now())
    }

    pub fn verify_at(&self, jws: &str, now: SystemTime) -> Result<Plan, Rejection> {
        if jws.is_empty() {
            return Err(Rejection::Malformed);
        }
        if jws.len() > MAX_JWS_BYTES {
            return Err(Rejection::TooLarge);
        }

        let parts = segments(jws)?;
        let header: Header =
            serde_json::from_slice(&parts.header).map_err(|_| Rejection::BadEncoding)?;
        // The algorithm is read before the chain is, and anything that is not ES256 is refused here
        // rather than by `webpki` later: `none` and `HS256` are the two spellings an attacker would
        // reach for first, and neither should get as far as a certificate being parsed.
        if header.alg != "ES256" {
            return Err(Rejection::UnsupportedAlgorithm);
        }

        let chain = header
            .x5c
            .iter()
            .map(|entry| CERT_BASE64.decode(entry).map(CertificateDer::from))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| Rejection::BadCertificateChain)?;
        let Some((leaf, intermediates)) = chain.split_first() else {
            return Err(Rejection::BadCertificateChain);
        };

        // The pinned root is the only anchor. `anchor_from_trusted_cert` reads the name and public
        // key out of the copy in this binary, so the chain is checked against Apple's key and not
        // against whatever certificate the client thought to send.
        let root = CertificateDer::from(self.root.as_slice());
        let anchors = [webpki::anchor_from_trusted_cert(&root).map_err(|_| Rejection::UntrustedChain)?];
        let end_entity = EndEntityCert::try_from(leaf).map_err(|_| Rejection::BadCertificateChain)?;
        let time = UnixTime::since_unix_epoch(now.duration_since(UNIX_EPOCH).unwrap_or_default());

        // The path, the signature on each link of it, and the validity dates of every certificate
        // in it. Nothing below this line runs unless the chain reached the pinned root.
        let path = end_entity
            .verify_for_usage(
                CHAIN_ALGORITHMS,
                &anchors,
                intermediates,
                time,
                AnyPurpose,
                None,
                None,
            )
            .map_err(|_| Rejection::UntrustedChain)?;

        // Apple's own two marker checks, on the certificates that were just verified.
        //
        // **The one that signed the leaf, not whichever entry of `x5c` happens to carry it.** Which
        // certificate that is, is `webpki`'s answer to give, and the answer is the first of the
        // path's intermediates — the same certificate Apple's own library checks as
        // `trusted_chain[1]`. Searching the rest of `x5c` for the marker instead would accept a
        // chain whose real issuer carries nothing, with Apple's public intermediate pasted in
        // beside it as decoration.
        let leaf = parse_certificate(leaf)?;
        if !has_marker(&leaf, LEAF_MARKER) {
            return Err(Rejection::NotAnAppStoreCertificate);
        }
        let issuer = path
            .intermediate_certificates()
            .next()
            .ok_or(Rejection::NotAnAppStoreCertificate)?;
        if !has_marker(&parse_certificate(&issuer.der())?, INTERMEDIATE_MARKER) {
            return Err(Rejection::NotAnAppStoreCertificate);
        }

        // ES256, named rather than inferred from the header, and verified with the leaf's key: the
        // signature covers the two segments as they were sent, which is why `signing_input` is a
        // slice of the original text instead of the decoded values re-encoded.
        //
        // **Verified with `ring` rather than with `webpki`'s ES256**, and the reason is an encoding
        // rather than a difference of opinion. `webpki`'s algorithms read the DER form that a
        // certificate's own signature is in; a JWS ES256 signature is the fixed `r || s` form from
        // RFC 7518, so a perfectly good receipt would fail a check made with the wrong one. `ring`
        // is the same library `webpki` verifies chains with, reached directly for the encoding this
        // document actually uses, and the key is the one the verified chain attests: the public key
        // out of the leaf certificate that just reached Apple's root.
        let key = leaf
            .tbs_certificate()
            .subject_public_key_info()
            .subject_public_key
            .raw_bytes();
        ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, key)
            .verify(parts.signing_input.as_bytes(), &parts.signature)
            .map_err(|_| Rejection::BadSignature)?;

        // Only now is anything the client wrote believed, and only to decide which product it is.
        let transaction: Transaction =
            serde_json::from_slice(&parts.payload).map_err(|_| Rejection::BadPayload)?;
        match transaction.bundle_id.as_deref() {
            Some(bundle) if bundle == self.bundle_id => {}
            Some(_) => return Err(Rejection::WrongBundle),
            None => return Err(Rejection::BadPayload),
        }

        let product = transaction
            .product_id
            .as_deref()
            .ok_or(Rejection::BadPayload)?;
        let Some((_, plan)) = PRODUCTS.iter().find(|(id, _)| *id == product) else {
            return Err(Rejection::UnknownProduct);
        };

        if transaction.revocation_date.is_some() {
            return Err(Rejection::Revoked);
        }
        // **A denial list rather than an insistence on `Production`**, and the direction matters: a
        // payload with no `environment` at all, or with a name Apple has not used before, is a
        // purchase this module does not recognise rather than a purchase it refuses, and refusing
        // one would meter a subscriber as free. What is denied is what cannot be a purchase. A
        // sandbox transaction is signed by Apple, names the real products and carries a real expiry,
        // and is handed out for nothing to anyone with a developer account, so believing it would
        // put the price of unlimited relay at one App Store Connect login; an Xcode one is signed by
        // a local test chain, which the pinned root already refuses, and is named here so that the
        // intent is checkable rather than implied.
        //
        // Matched without regard to case, because a spelling this list misses is a spelling that
        // buys unlimited relay, while the cost of being wrong in the other direction is a name
        // Apple has not used yet. What the list still misses is any *other* environment Apple tests
        // in — there is no way to enumerate those from here, and a purchase in one of them would
        // have to be refused by name once it exists.
        let environment = transaction.environment.as_deref();
        if environment.is_some_and(|name| {
            ["sandbox", "xcode"]
                .iter()
                .any(|denied| name.trim().eq_ignore_ascii_case(denied))
        }) {
            return Err(Rejection::NotARealPurchase);
        }
        let expires = transaction.expires_date.ok_or(Rejection::NoExpiry)?;
        if expires <= unix_millis(now) {
            return Err(Rejection::Expired);
        }

        Ok(*plan)
    }

    /// The plan to meter by, given what the client claims and what a receipt said.
    ///
    /// `verified` is the verdict on the receipt the client sent, or `None` when it sent none.
    ///
    /// **A receipt that verifies wins outright, including downwards.** A client claiming `pro` over
    /// a receipt for `relay` is claiming something Apple does not agree with, and the same has to
    /// hold for a subscription that has since lapsed: the receipt still verifies and still names
    /// the product, and the expiry is inside the verdict. Where the claim is the only thing left,
    /// the switch decides: the free allowance, unless an operator has opened it, which the module
    /// comment explains and the startup log states.
    pub fn resolve(&self, claimed: Plan, verified: Option<Result<Plan, Rejection>>) -> Resolved {
        match verified {
            Some(Ok(plan)) => Resolved {
                plan,
                trust: Trust::Verified,
                rejected: None,
            },
            Some(Err(reason)) => {
                warn!(reason = reason.reason(), "receipt did not verify");
                self.fallback(claimed, Some(reason))
            }
            None => self.fallback(claimed, None),
        }
    }

    /// What an unproven client is metered by: the free allowance, or its own claim when the
    /// operator has opened the switch that believes claims.
    ///
    /// A claim of `free` is not a claim at all, so it reads as `neither` either way: there was no
    /// plan to believe, and a log line should not say there was. The rejection travels with the
    /// answer in both directions, because "why is this client on the free plan" is answered by the
    /// reason the receipt was refused as much as by the switch.
    fn fallback(&self, claimed: Plan, rejected: Option<Rejection>) -> Resolved {
        if self.trust_claims && claimed != Plan::Free {
            Resolved {
                plan: claimed,
                trust: Trust::Claimed,
                rejected,
            }
        } else {
            Resolved {
                plan: Plan::Free,
                trust: Trust::None,
                rejected,
            }
        }
    }
}

/// One session's answer about a receipt, kept so that a client cannot make the relay verify a JWS
/// once per message.
///
/// A session is one signalling socket, and a client may send `ConnectToHost` on it more than once:
/// a retry after a `quotaExceeded`, a second Mac. Verifying again for each of those is work a
/// hostile client could ask for on a loop, so the verdict is remembered and re-resolved against the
/// claim in front of it. That second part matters because the claim is not part of the receipt: the
/// same verified document with a different claim is the same Apple answer, and it costs nothing to
/// reuse it.
///
/// **Keyed on the text the signature covers**, which is the header and payload rather than the
/// whole receipt, because that is the part the plan comes from: the same document with a
/// differently spelled signature segment is the same question, and is not asked twice.
///
/// **How many are verified is bounded.** A key alone would let a client buy as much verification as
/// it liked by varying one byte per message, so a session gets `MAX_RECEIPTS_PER_SESSION` of them
/// and is metered by its claim after that. An honest client sends one per connect attempt and never
/// sees the limit; the client that reaches it is doing something an operator wants to see in the
/// log rather than something to accommodate.
///
/// The cache holds the document in front of it and not every document the session has seen, so a
/// client that cycles through receipts loses the earlier verdicts to the count — which is the case
/// the count exists to bound, and not one an honest client is in.
///
/// The receipt is held here for the life of the connection and nowhere else. It is never logged.
#[derive(Default)]
pub struct ReceiptCache {
    seen: Option<(String, Result<Plan, Rejection>)>,
    verified: usize,
}

/// Distinct documents one session may have verified. Generous next to what the app sends — one per
/// connect attempt, on a socket it opens for that attempt and closes — and small enough that a
/// session cannot be used as a certificate-verification engine.
const MAX_RECEIPTS_PER_SESSION: usize = 8;

impl ReceiptCache {
    /// The plan for this connect request, verifying the receipt only if it has not been seen and the
    /// session has not spent its share of verification.
    pub fn resolve(
        &mut self,
        verifier: &StoreKitVerifier,
        claimed: Plan,
        jws: Option<&str>,
    ) -> Resolved {
        let Some(jws) = jws else {
            return verifier.resolve(claimed, None);
        };
        let document = match segments(jws) {
            Ok(parts) => parts.signing_input.to_string(),
            // Not a compact JWS, so there is no document to key on and no certificate in it to
            // verify. Answered — and refused — here rather than spending the session's share of
            // verification on a string that has nothing in it.
            Err(reason) => return verifier.resolve(claimed, Some(Err(reason))),
        };

        if !self.seen.as_ref().is_some_and(|(seen, _)| *seen == document) {
            if self.verified >= MAX_RECEIPTS_PER_SESSION {
                // Fail closed, and the same place a receipt that did not verify lands: the claim.
                return verifier.resolve(claimed, Some(Err(Rejection::TooManyReceipts)));
            }
            self.verified += 1;
            self.seen = Some((document, verifier.verify(jws)));
        }
        let verdict = self.seen.as_ref().map(|(_, verdict)| *verdict);
        verifier.resolve(claimed, verdict)
    }
}

/// The decoded header. Only the two fields that matter are read; `kid` and `typ` are Apple's.
#[derive(Deserialize)]
struct Header {
    alg: String,
    #[serde(default)]
    x5c: Vec<String>,
}

/// The fields of a transaction this module reads, none of them required by `serde` so that a
/// missing one is a named rejection rather than a parse error. Apple sends more than this.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Transaction {
    bundle_id: Option<String>,
    product_id: Option<String>,
    /// Milliseconds since the epoch, which is the unit every date in these payloads uses.
    expires_date: Option<i64>,
    revocation_date: Option<i64>,
    /// `Production`, `Sandbox` or `Xcode`. Read only to refuse the two that are not a purchase.
    environment: Option<String>,
}

/// A compact JWS, taken apart: the text the signature covers, and the three decoded parts.
struct Segments<'a> {
    /// `header.payload`, as it arrived. Sliced out of the original text rather than rebuilt from the
    /// decoded values, because the signature covers the encoded bytes and re-encoding would verify
    /// the relay's spelling of the JWS instead of the sender's.
    signing_input: &'a str,
    header: Vec<u8>,
    payload: Vec<u8>,
    signature: Vec<u8>,
}

/// Splits a compact JWS into its three parts. Every way of failing here is `Malformed` or
/// `BadEncoding`, and all of them end at the free allowance.
fn segments(jws: &str) -> Result<Segments<'_>, Rejection> {
    let mut parts = jws.split('.');
    let (Some(header), Some(payload), Some(signature), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(Rejection::Malformed);
    };

    let signing_input = &jws[..jws.len() - signature.len() - 1];
    Ok(Segments {
        signing_input,
        header: SEGMENT_BASE64
            .decode(header)
            .map_err(|_| Rejection::BadEncoding)?,
        payload: SEGMENT_BASE64
            .decode(payload)
            .map_err(|_| Rejection::BadEncoding)?,
        signature: SEGMENT_BASE64
            .decode(signature)
            .map_err(|_| Rejection::BadEncoding)?,
    })
}

/// Whether a certificate carries an extension with this OID, which is the check Apple's own library
/// makes: any extension, not specifically an EKU or a policy.
fn has_marker(certificate: &x509_cert::Certificate, oid: ObjectIdentifier) -> bool {
    certificate
        .tbs_certificate()
        .extensions()
        .is_some_and(|extensions| extensions.iter().any(|extension| extension.extn_id == oid))
}

/// A certificate that cannot be parsed is a rejection rather than a `false` in the caller, because
/// "this is not Apple's certificate" and "this is not a certificate" look the same from a marker
/// check and only one of them is a client's fault.
fn parse_certificate(
    certificate: &CertificateDer<'_>,
) -> Result<x509_cert::Certificate, Rejection> {
    x509_cert::Certificate::from_der(certificate.as_ref())
        .map_err(|_| Rejection::BadCertificateChain)
}

/// Milliseconds since the epoch, which is the unit the payload's dates are in.
fn unix_millis(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every string the log can carry, so that a rename does not quietly change what an operator
    /// greps for. `neither` rather than `none` because the question the line answers is "was this
    /// plan proven, claimed, or neither".
    #[test]
    fn the_log_vocabulary_is_stable() {
        assert_eq!(Trust::Verified.as_str(), "verified");
        assert_eq!(Trust::Claimed.as_str(), "claimed");
        assert_eq!(Trust::None.as_str(), "neither");
    }

    /// The reasons are the operator's index into "why is this client on the free plan", so they are
    /// pinned by name and checked for the two properties that make them greppable: lowercase, and
    /// no spaces.
    #[test]
    fn every_rejection_has_a_greppable_reason() {
        let all = [
            Rejection::Malformed,
            Rejection::TooLarge,
            Rejection::BadEncoding,
            Rejection::UnsupportedAlgorithm,
            Rejection::BadCertificateChain,
            Rejection::UntrustedChain,
            Rejection::NotAnAppStoreCertificate,
            Rejection::BadSignature,
            Rejection::BadPayload,
            Rejection::WrongBundle,
            Rejection::UnknownProduct,
            Rejection::NoExpiry,
            Rejection::Expired,
            Rejection::Revoked,
            Rejection::NotARealPurchase,
            Rejection::TooManyReceipts,
        ];
        for rejection in all {
            let reason = rejection.reason();
            assert!(
                reason.chars().all(|c| c.is_ascii_lowercase() || c == '_'),
                "{reason:?} should be lowercase with underscores only"
            );
        }
    }

    /// `Result` is not `Debug`-comparable here, so the shape failures are checked by reason.
    fn segment_error(jws: &str) -> Option<&'static str> {
        segments(jws).err().map(Rejection::reason)
    }

    #[test]
    fn a_receipt_with_no_shape_at_all_is_malformed() {
        for jws in ["", "one", "one.two", "one.two.three.four"] {
            assert_eq!(
                segment_error(jws),
                Some("malformed"),
                "{jws:?} is not a compact JWS"
            );
        }
    }

    #[test]
    fn the_signature_input_is_the_text_that_was_signed() {
        // "eyJhIjoxfQ" is `{"a":1}` and "c2ln" is `sig`, and the signed text has to come back
        // exactly as it was sent rather than re-encoded from what the segments decode to.
        let parts = segments("eyJhIjoxfQ.c2ln.c2ln").expect("should split");
        assert_eq!(parts.signing_input, "eyJhIjoxfQ.c2ln");
        assert_eq!(parts.header, br#"{"a":1}"#);
        assert_eq!(parts.payload, b"sig");
        assert_eq!(parts.signature, b"sig");
    }

    #[test]
    fn a_segment_that_is_not_base64url_is_refused() {
        assert_eq!(segment_error("!!!!.c2ln.c2ln"), Some("bad_encoding"));
        assert_eq!(segment_error("c2ln.!!!!.c2ln"), Some("bad_encoding"));
        assert_eq!(segment_error("c2ln.c2ln.!!!!"), Some("bad_encoding"));
    }

    #[test]
    fn an_oversized_receipt_is_refused_before_it_is_parsed() {
        let verifier = StoreKitVerifier::apple(true);
        let huge = "a".repeat(MAX_JWS_BYTES + 1);
        assert_eq!(verifier.verify(&huge), Err(Rejection::TooLarge));

        // And an empty one, which is what a client that meant to send nothing sends.
        assert_eq!(verifier.verify(""), Err(Rejection::Malformed));
    }

    /// The limit has to be roomier than the receipts Apple issues, or a subscriber is metered as
    /// free by an arithmetic accident. What a real one weighs is checked in `tests/storekit.rs`,
    /// against a receipt the test generates; this is the floor under that, as a compile-time
    /// assertion so that lowering the limit is a build failure rather than a test failure.
    const _: () = assert!(MAX_JWS_BYTES >= 8 * 1024, "a real receipt is a few kilobytes");

    // MARK: - Resolution

    fn verifier(trust_claims: bool) -> StoreKitVerifier {
        StoreKitVerifier::new(APPLE_ROOT_CA_G3, APP_BUNDLE_ID, trust_claims)
    }

    /// The three paths, as a table, because the log line is the thing an operator reads and the
    /// three words have to mean what they say.
    #[test]
    fn a_verified_receipt_is_the_only_thing_that_reports_verified() {
        let verifier = verifier(true);

        let resolved = verifier.resolve(Plan::Pro, Some(Ok(Plan::Relay)));
        assert_eq!(resolved.plan, Plan::Relay, "Apple's answer wins over the claim");
        assert_eq!(resolved.trust, Trust::Verified);
        assert_eq!(resolved.rejected, None);

        let resolved = verifier.resolve(Plan::Pro, Some(Err(Rejection::Expired)));
        assert_eq!(resolved.plan, Plan::Pro);
        assert_eq!(resolved.trust, Trust::Claimed);
        assert_eq!(resolved.rejected, Some(Rejection::Expired));

        let resolved = verifier.resolve(Plan::Pro, None);
        assert_eq!(resolved.plan, Plan::Pro);
        assert_eq!(resolved.trust, Trust::Claimed);
        assert_eq!(resolved.rejected, None, "sending nothing is not a rejection");
    }

    /// A client that claims nothing, which is most of them, is `neither` rather than `claimed`:
    /// there was no claim to believe, and the line should not suggest there was.
    #[test]
    fn a_client_with_nothing_to_say_is_neither() {
        let resolved = verifier(true).resolve(Plan::Free, None);
        assert_eq!(resolved.plan, Plan::Free);
        assert_eq!(resolved.trust, Trust::None);
    }

    /// The verified path is not a way to be metered as free by claiming less: a receipt is what the
    /// client bought, and claiming `free` over one does not downgrade it. That direction costs the
    /// relay nothing and the alternative is a client's own string deciding its plan again.
    #[test]
    fn a_verified_receipt_is_not_downgraded_by_a_modest_claim() {
        let resolved = verifier(true).resolve(Plan::Free, Some(Ok(Plan::Plus)));
        assert_eq!(resolved.plan, Plan::Plus);
        assert_eq!(resolved.trust, Trust::Verified);
    }

    /// The transition switch: with claims untrusted, a plan that was not proven is the free plan,
    /// whatever was claimed, and the log says `neither` so the drop is visible as a rise in that
    /// word rather than as a rise in refusals.
    #[test]
    fn untrusted_claims_fall_to_free() {
        let verifier = verifier(false);
        assert!(!verifier.trusts_claims());

        for claimed in [Plan::Relay, Plan::Plus, Plan::Pro] {
            let resolved = verifier.resolve(claimed, None);
            assert_eq!(resolved.plan, Plan::Free, "{claimed:?} was never proven");
            assert_eq!(resolved.trust, Trust::None);

            let resolved = verifier.resolve(claimed, Some(Err(Rejection::BadSignature)));
            assert_eq!(resolved.plan, Plan::Free);
            assert_eq!(resolved.trust, Trust::None);
            assert_eq!(resolved.rejected, Some(Rejection::BadSignature));
        }

        // A verified receipt still works with the fallback off, which is the whole point of it.
        let resolved = verifier.resolve(Plan::Free, Some(Ok(Plan::Pro)));
        assert_eq!(resolved.plan, Plan::Pro);
        assert_eq!(resolved.trust, Trust::Verified);
    }

    // MARK: - The session cache

    /// A client that sends the same receipt twice on one socket is verified once. The test is the
    /// cache's own state rather than a counter, because what matters is that the second answer came
    /// from the first verification and not from a second one.
    #[test]
    fn the_same_receipt_is_verified_once_per_session() {
        let mut cache = ReceiptCache::default();
        let verifier = verifier(true);

        let first = cache.resolve(&verifier, Plan::Pro, Some("not-a-receipt"));
        assert_eq!(first.rejected, Some(Rejection::Malformed));
        assert_eq!(first.plan, Plan::Pro, "claimed, and the fallback is on");

        // Same receipt, different claim: the verdict is reused, and the new claim is applied to it.
        let second = cache.resolve(&verifier, Plan::Relay, Some("not-a-receipt"));
        assert_eq!(second.rejected, Some(Rejection::Malformed));
        assert_eq!(second.plan, Plan::Relay);
        assert_eq!(second.trust, Trust::Claimed);

        // Nothing at all is answered without touching the cache, so a client cannot spend one
        // verification and then claim whatever it likes with the receipt left out.
        let third = cache.resolve(&verifier, Plan::Free, None);
        assert_eq!(third.plan, Plan::Free);
        assert_eq!(third.trust, Trust::None);
    }

    /// A receipt that reaches the verifier and is refused there: the shape of a compact JWS with
    /// nothing in it, so the chain check is what refuses it and the session's share of verification
    /// is what it spends.
    fn shapeless(payload: &str) -> String {
        let header = SEGMENT_BASE64.encode(br#"{"alg":"ES256","x5c":[]}"#);
        let payload = SEGMENT_BASE64.encode(payload.as_bytes());
        let signature = SEGMENT_BASE64.encode(b"sig");
        format!("{header}.{payload}.{signature}")
    }

    /// A different document is a different question, and the first answer is not reused for it.
    #[test]
    fn a_different_receipt_is_verified_again() {
        let mut cache = ReceiptCache::default();
        let verifier = verifier(true);

        let first = cache.resolve(&verifier, Plan::Free, Some(&shapeless("one")));
        assert_eq!(first.rejected, Some(Rejection::BadCertificateChain));
        assert_eq!(cache.verified, 1);

        let second = cache.resolve(&verifier, Plan::Free, Some(&shapeless("two")));
        assert_eq!(second.rejected, Some(Rejection::BadCertificateChain));
        assert_eq!(cache.verified, 2, "a different payload is a different receipt");
    }

    /// The same document spelled differently is the same question. The key is the text the signature
    /// covers, so a receipt whose signature segment is written another way is answered from what is
    /// already there rather than verified again — which is the property the cap exists to bound.
    #[test]
    fn the_same_document_spelled_differently_is_not_verified_again() {
        let mut cache = ReceiptCache::default();
        let verifier = verifier(true);

        let header = SEGMENT_BASE64.encode(br#"{"alg":"ES256","x5c":[]}"#);
        let payload = SEGMENT_BASE64.encode(b"one");
        let first = format!("{header}.{payload}.{}", SEGMENT_BASE64.encode(b"sig"));
        let respelled = format!("{header}.{payload}.{}", SEGMENT_BASE64.encode(b"other"));

        assert_eq!(
            cache.resolve(&verifier, Plan::Free, Some(&first)).rejected,
            Some(Rejection::BadCertificateChain)
        );
        assert_eq!(cache.verified, 1);

        assert_eq!(
            cache.resolve(&verifier, Plan::Free, Some(&respelled)).rejected,
            Some(Rejection::BadCertificateChain),
            "the verdict is the one already reached"
        );
        assert_eq!(cache.verified, 1, "and nothing was verified again");
    }

    /// A receipt with no shape at all has no document to key on and no certificate in it, so it is
    /// refused without spending the session's share of verification.
    #[test]
    fn a_receipt_that_is_not_a_jws_costs_nothing() {
        let mut cache = ReceiptCache::default();
        let verifier = verifier(true);

        for _ in 0..(MAX_RECEIPTS_PER_SESSION * 4) {
            let resolved = cache.resolve(&verifier, Plan::Relay, Some("not-a-receipt"));
            assert_eq!(resolved.rejected, Some(Rejection::Malformed));
        }
        assert_eq!(cache.verified, 0);
    }

    /// A session cannot buy unbounded verification by varying one byte per message: the count stops
    /// at the limit, and what the client gets past it is its claim rather than a refusal, because a
    /// client that has sent its share of receipts is metered, not disconnected.
    #[test]
    fn one_session_can_only_have_so_many_receipts_verified() {
        let mut cache = ReceiptCache::default();
        let verifier = verifier(true);

        for attempt in 0..MAX_RECEIPTS_PER_SESSION {
            let receipt = shapeless(&format!("payload {attempt}"));
            let resolved = cache.resolve(&verifier, Plan::Relay, Some(&receipt));
            assert_eq!(
                resolved.rejected,
                Some(Rejection::BadCertificateChain),
                "receipt {attempt} should have been read"
            );
        }
        assert_eq!(cache.verified, MAX_RECEIPTS_PER_SESSION);

        let resolved = cache.resolve(&verifier, Plan::Relay, Some(&shapeless("one too many")));
        assert_eq!(resolved.rejected, Some(Rejection::TooManyReceipts));
        assert_eq!(resolved.plan, Plan::Relay, "metered by the claim, not refused");
        assert_eq!(
            cache.verified, MAX_RECEIPTS_PER_SESSION,
            "and the count does not move"
        );

        // The receipt already at the front of the cache is still answered from it, which is the
        // case an honest client is in: it repeats the same receipt, and it is never told there is
        // a limit. Only a receipt the session has not just shown is turned away.
        let repeated = shapeless(&format!("payload {}", MAX_RECEIPTS_PER_SESSION - 1));
        assert_eq!(
            cache.resolve(&verifier, Plan::Relay, Some(&repeated)).rejected,
            Some(Rejection::BadCertificateChain)
        );
        assert_eq!(
            cache.resolve(&verifier, Plan::Relay, Some(&shapeless("payload 0"))).rejected,
            Some(Rejection::TooManyReceipts)
        );
    }
}
