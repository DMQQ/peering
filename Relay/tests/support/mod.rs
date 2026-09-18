//! A stand-in App Store chain, for the receipt tests.
//!
//! Apple's own chain cannot be used in a test. It is not in the repository, it expires, and getting
//! a real receipt means buying something, so the tests mint their own: three certificates with the
//! same shape as Apple's, signed by a root the test then pins. That exercises every check the
//! verifier makes — the path, the signature on each link, the dates, the marker extensions, the
//! payload — against a key the test holds, and it is worth being precise about what it does *not*
//! prove: that Apple's particular certificates satisfy those checks. Only a real purchase can prove
//! that, and it is called out in the report that came with this change.
//!
//! The generator is deliberately not `#[cfg(test)]` in `src/`. Integration tests are a separate
//! crate and cannot see that, and the alternative — a feature flag on `rcgen` in the relay's own
//! dependency list — would put a certificate generator into the binary that ships.

use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use peeringd::storekit::StoreKitVerifier;
use p256::ecdsa::{Signature, SigningKey, signature::Signer};
use p256::pkcs8::DecodePrivateKey as _;
use rcgen::{
    BasicConstraints, Certificate, CertificateParams, CustomExtension, DnType,
    ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair, KeyUsagePurpose, date_time_ymd,
};
use rustls_pki_types::CertificateDer;
use serde_json::json;

/// The extension Apple puts on a receipt-signing certificate, and the one it puts on the
/// intermediate that issues them. The same two values are in `src/storekit.rs`; they are repeated
/// here rather than exported because a test that imported the constant would not notice it being
/// changed to the wrong OID, which is the one mistake this pair can make.
pub const LEAF_MARKER_OID: &[u64] = &[1, 2, 840, 113_635, 100, 6, 11, 1];
pub const INTERMEDIATE_MARKER_OID: &[u64] = &[1, 2, 840, 113_635, 100, 6, 2, 1];

/// A three-certificate chain in the shape a real `x5c` carries, and the key that signs receipts
/// with its leaf.
pub struct TestChain {
    /// The certificate the test pins as its trust anchor. In a real receipt this is Apple's root.
    pub root: CertificateDer<'static>,
    pub intermediate: CertificateDer<'static>,
    pub leaf: CertificateDer<'static>,
    /// The leaf's private key, which is what makes a receipt in this chain verifiable at all.
    signing: SigningKey,
}

/// What a chain is built with, so each test can ask for the one thing it is about instead of
/// sharing a fixture that quietly stops covering it.
#[derive(Clone)]
pub struct ChainOptions {
    /// Whether the leaf carries Apple's signing-certificate marker. Off is the developer
    /// certificate case: a real, Apple-issued-in-spirit certificate that is not a receipt signer.
    pub leaf_marker: bool,
    /// The same for the intermediate's marker.
    pub intermediate_marker: bool,
    /// Whether the leaf carries an extended key usage extension at all. Both are built, because
    /// the verifier deliberately does not require one and neither arrangement should be refused.
    pub leaf_eku: Option<ExtendedKeyUsagePurpose>,
    /// Whether the whole chain expired in 2020, for the case where the certificates are the
    /// problem rather than the payload.
    pub lapsed: bool,
}

impl Default for ChainOptions {
    fn default() -> Self {
        Self {
            leaf_marker: true,
            intermediate_marker: true,
            leaf_eku: None,
            lapsed: false,
        }
    }
}

impl TestChain {
    /// A chain that would verify if it were Apple's, which is the fixture every refusal test
    /// changes exactly one thing about.
    pub fn genesis() -> Self {
        Self::with(ChainOptions::default())
    }

    pub fn with(options: ChainOptions) -> Self {
        let (root, root_params, root_key) = authority("Test Root CA", &options, false);
        let (_, intermediate_params, intermediate_key) = authority(
            "Test Receipt Signing Intermediate",
            &options,
            options.intermediate_marker,
        );
        let intermediate = intermediate_params
            .signed_by(
                &intermediate_key,
                &Issuer::from_params(&root_params, &root_key),
            )
            .expect("the intermediate should be signed by the root");

        let leaf_key = KeyPair::generate().expect("should generate a P-256 key");
        let mut leaf_params = CertificateParams::new(Vec::new()).expect("empty params are valid");
        leaf_params
            .distinguished_name
            .push(DnType::CommonName, "Test Receipt Signing");
        leaf_params.is_ca = IsCa::ExplicitNoCa;
        leaf_params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        leaf_params.extended_key_usages = options.leaf_eku.into_iter().collect();
        if options.leaf_marker {
            leaf_params.custom_extensions.push(CustomExtension::from_oid_content(
                LEAF_MARKER_OID,
                Vec::new(),
            ));
        }
        if options.lapsed {
            leaf_params.not_after = date_time_ymd(2020, 1, 1);
        }
        let leaf = leaf_params
            .signed_by(
                &leaf_key,
                &Issuer::from_params(&intermediate_params, &intermediate_key),
            )
            .expect("the leaf should be signed by the intermediate");

        // The JWS signing key is the leaf's own key, taken out of rcgen in PKCS#8 and handed to the
        // ECDSA signer. If these ever stopped being the same key, every test below would fail at
        // the signature check rather than at the assertion, which is the loud way round.
        let secret = p256::SecretKey::from_pkcs8_der(&leaf_key.serialize_der())
            .expect("the leaf key should be readable as PKCS#8");
        let signing = SigningKey::from(&secret);

        Self {
            root: root.der().clone(),
            intermediate: intermediate.der().clone(),
            leaf: leaf.der().clone(),
            signing,
        }
    }

    /// A verifier pinned to this chain's root, which is the stand-in for Apple's.
    pub fn verifier(&self, trust_claims: bool) -> StoreKitVerifier {
        StoreKitVerifier::new(self.root.as_ref().to_vec(), "pl.dmq.peering", trust_claims)
    }

    /// The chain as a receipt header carries it: leaf, intermediate, root.
    ///
    /// Standard base64 with its padding, which is what RFC 7515 specifies for `x5c` and what Apple
    /// sends. The segments of the JWS are base64url and this is not: the two are different
    /// encodings of different things, and a certificate that is base64url on the way here is one
    /// the verifier will refuse to read.
    pub fn x5c(&self) -> Vec<String> {
        [&self.leaf, &self.intermediate, &self.root]
            .iter()
            .map(|certificate| STANDARD.encode(certificate.as_ref()))
            .collect()
    }

    /// The header a real receipt carries: ES256 and the chain.
    pub fn header(&self) -> serde_json::Value {
        json!({ "alg": "ES256", "x5c": self.x5c() })
    }

    /// A signed receipt over `payload`.
    pub fn jws(&self, payload: &str) -> String {
        self.jws_with(&self.header(), payload)
    }

    /// A receipt with a header the caller chose, signed with the leaf's key.
    ///
    /// The signature is always made, including for headers whose `alg` is nonsense, so that the
    /// test can be about the header rather than about a missing signature.
    pub fn jws_with(&self, header: &serde_json::Value, payload: &str) -> String {
        let header = URL_SAFE_NO_PAD.encode(serde_json::to_vec(header).expect("header encodes"));
        let payload = URL_SAFE_NO_PAD.encode(payload.as_bytes());
        let signature = self.sign(&format!("{header}.{payload}"));
        format!("{header}.{payload}.{signature}")
    }

    /// A raw ES256 signature over the signed text, base64url, as JWS spells it.
    pub fn sign(&self, signing_input: &str) -> String {
        let signature: Signature = self.signing.sign(signing_input.as_bytes());
        URL_SAFE_NO_PAD.encode(signature.to_bytes())
    }
}

/// A prefix and a key, with the shape a CA has when the chain is meant to work.
fn authority(
    name: &str,
    options: &ChainOptions,
    marker: bool,
) -> (Certificate, CertificateParams, KeyPair) {
    let mut params = CertificateParams::new(Vec::new()).expect("empty params are valid");
    params
        .distinguished_name
        .push(DnType::CommonName, name);
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    if marker {
        params
            .custom_extensions
            .push(CustomExtension::from_oid_content(
                INTERMEDIATE_MARKER_OID,
                Vec::new(),
            ));
    }
    if options.lapsed {
        params.not_after = date_time_ymd(2020, 1, 1);
    }

    let key = KeyPair::generate().expect("should generate a P-256 key");
    let certificate = params
        .self_signed(&key)
        .expect("a self-signed authority should be built");
    (certificate, params, key)
}

/// A transaction payload of the shape Apple signs, with the dates relative to now.
///
/// Only the four fields the verifier reads are interesting, but the ones a real payload carries
/// alongside them are here too: a parser that tripped over an unexpected field would be a parser
/// that refused real receipts.
pub fn transaction(bundle: &str, product: &str, expires_in_days: i64) -> String {
    let now = now_millis();
    json!({
        "transactionId": "2000000000000001",
        "originalTransactionId": "2000000000000001",
        "bundleId": bundle,
        "productId": product,
        "purchaseDate": now - 60_000,
        "originalPurchaseDate": now - 60_000,
        "expiresDate": now + expires_in_days * 24 * 60 * 60 * 1000,
        "quantity": 1,
        "type": "Auto-Renewable Subscription",
        "inAppOwnershipType": "PURCHASED",
        "signedDate": now,
        "environment": "Production",
        "storefront": "GBR",
    })
    .to_string()
}

/// The same payload with Apple's revocation stamp on it, which is what a refund looks like.
pub fn revoked_transaction(bundle: &str, product: &str) -> String {
    let mut payload = payload_of(bundle, product);
    payload["revocationDate"] = json!(now_millis() - 60_000);
    payload["revocationReason"] = json!(0);
    payload.to_string()
}

/// The same payload as a sandbox purchase: Apple-signed, naming the real product, and free to
/// anyone who can sign in to the sandbox with an account their developer membership gave them.
pub fn sandbox_transaction(bundle: &str, product: &str) -> String {
    let mut payload = payload_of(bundle, product);
    payload["environment"] = json!("Sandbox");
    payload.to_string()
}

/// The same payload with no environment field at all, which is what a producer that predates the
/// field sends and what the verifier has to keep reading.
pub fn environmentless_transaction(bundle: &str, product: &str) -> String {
    let mut payload = payload_of(bundle, product);
    payload.as_object_mut().expect("an object").remove("environment");
    payload.to_string()
}

fn payload_of(bundle: &str, product: &str) -> serde_json::Value {
    serde_json::from_str(&transaction(bundle, product, 30)).expect("the payload should parse")
}

pub fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("the test machine's clock is after 1970")
        .as_millis() as i64
}
