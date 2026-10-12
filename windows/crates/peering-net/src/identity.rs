//! The host's long-term identity: a persistent P-256 key, a device id, and a certificate minted at every start.

use std::fmt;

use peering_core::ports::secret_store::SecretStore;
use peering_wire::relay_proof::ProofSigner;
use rustls_pki_types::PrivatePkcs8KeyDer;
use rcgen::{
    CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa, KeyPair as CertKeyPair,
    KeyUsagePurpose, PKCS_ECDSA_P256_SHA256, SerialNumber,
};
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_ASN1_SIGNING};
use time::{Duration, OffsetDateTime};

pub const KEY_SECRET_NAME: &str = "host-identity-key";
pub const DEVICE_ID_SECRET_NAME: &str = "host-device-id";

const CERTIFICATE_LIFETIME_DAYS: i64 = 3650;
const ORGANISATION: &str = "Peering";

#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error("the identity key could not be stored")]
    KeyNotStored,
    #[error("the stored identity key is not a P-256 PKCS8 key")]
    KeyRejected,
    #[error("the device id could not be stored")]
    DeviceIdNotStored,
    #[error("the stored device id is not valid UTF-8")]
    DeviceIdNotUtf8,
    #[error("the system random source failed")]
    Random,
    #[error("the certificate could not be built: {0}")]
    Certificate(String),
    #[error("the signature could not be produced")]
    Signing,
}

pub struct HostIdentity {
    device_id: String,
    device_name: String,
    pkcs8: Vec<u8>,
    key_pair: EcdsaKeyPair,
    certificate_der: Vec<u8>,
}

impl HostIdentity {
    /// Loads the stored key and device id, creating and storing them when absent, then mints a certificate for
    /// `device_name`. The stored key is never replaced by a failed read: every paired peer pins it.
    pub fn load(store: &dyn SecretStore, device_name: &str) -> Result<Self, IdentityError> {
        let device_id = load_or_create_device_id(store)?;
        let pkcs8 = load_or_create_key(store)?;
        Self::from_parts(device_id, device_name, pkcs8)
    }

    fn from_parts(device_id: String, device_name: &str, pkcs8: Vec<u8>) -> Result<Self, IdentityError> {
        let key_pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &pkcs8, &SystemRandom::new())
            .map_err(|_| IdentityError::KeyRejected)?;
        let certificate_der = mint_certificate(&pkcs8, device_name)?;
        Ok(Self {
            device_id,
            device_name: device_name.to_owned(),
            pkcs8,
            key_pair,
            certificate_der,
        })
    }

    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    /// The pin value: `0x04 || X || Y`, 65 bytes.
    pub fn public_key_bytes(&self) -> Vec<u8> {
        self.key_pair.public_key().as_ref().to_vec()
    }

    pub fn certificate_der(&self) -> &[u8] {
        &self.certificate_der
    }

    pub fn private_key_pkcs8(&self) -> &[u8] {
        &self.pkcs8
    }

    /// ECDSA P-256 over SHA-256 of `message`, DER encoded.
    pub fn sign(&self, message: &[u8]) -> Result<Vec<u8>, IdentityError> {
        let signature = self
            .key_pair
            .sign(&SystemRandom::new(), message)
            .map_err(|_| IdentityError::Signing)?;
        Ok(signature.as_ref().to_vec())
    }
}

impl fmt::Debug for HostIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HostIdentity")
            .field("device_id", &self.device_id)
            .field("device_name", &self.device_name)
            .finish_non_exhaustive()
    }
}

impl ProofSigner for HostIdentity {
    fn public_key(&self) -> Vec<u8> {
        self.public_key_bytes()
    }

    /// An empty signature on failure: the relay rejects it, so a failed signature never authenticates.
    fn sign(&self, message: &[u8]) -> Vec<u8> {
        HostIdentity::sign(self, message).unwrap_or_default()
    }
}

fn load_or_create_key(store: &dyn SecretStore) -> Result<Vec<u8>, IdentityError> {
    if let Some(stored) = store.read(KEY_SECRET_NAME) {
        return Ok(stored);
    }
    let generated = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &SystemRandom::new())
        .map_err(|_| IdentityError::Random)?;
    let pkcs8 = generated.as_ref().to_vec();
    if !store.write(KEY_SECRET_NAME, &pkcs8) {
        return Err(IdentityError::KeyNotStored);
    }
    Ok(pkcs8)
}

fn load_or_create_device_id(store: &dyn SecretStore) -> Result<String, IdentityError> {
    if let Some(stored) = store.read(DEVICE_ID_SECRET_NAME) {
        return String::from_utf8(stored).map_err(|_| IdentityError::DeviceIdNotUtf8);
    }
    let device_id = new_device_id()?;
    if !store.write(DEVICE_ID_SECRET_NAME, device_id.as_bytes()) {
        return Err(IdentityError::DeviceIdNotStored);
    }
    Ok(device_id)
}

/// A random version 4 UUID, uppercase and hyphenated.
pub fn new_device_id() -> Result<String, IdentityError> {
    let mut bytes = [0u8; 16];
    SystemRandom::new().fill(&mut bytes).map_err(|_| IdentityError::Random)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = hex::encode_upper(bytes);
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    ))
}

fn mint_certificate(pkcs8: &[u8], device_name: &str) -> Result<Vec<u8>, IdentityError> {
    let key = CertKeyPair::from_pkcs8_der_and_sign_algo(
        &PrivatePkcs8KeyDer::from(pkcs8),
        &PKCS_ECDSA_P256_SHA256,
    )
    .map_err(|error| IdentityError::Certificate(error.to_string()))?;

    let mut serial = [0u8; 16];
    SystemRandom::new().fill(&mut serial).map_err(|_| IdentityError::Random)?;
    serial[0] &= 0x7f;

    let mut subject = DistinguishedName::new();
    subject.push(DnType::CommonName, device_name);
    subject.push(DnType::OrganizationName, ORGANISATION);

    let now = OffsetDateTime::now_utc();
    let mut params = CertificateParams::default();
    params.serial_number = Some(SerialNumber::from_slice(&serial));
    params.distinguished_name = subject;
    params.not_before = now - Duration::hours(1);
    params.not_after = now + Duration::days(CERTIFICATE_LIFETIME_DAYS);
    params.is_ca = IsCa::ExplicitNoCa;
    params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
    params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];

    let certificate = params
        .self_signed(&key)
        .map_err(|error| IdentityError::Certificate(error.to_string()))?;
    Ok(certificate.der().to_vec())
}
