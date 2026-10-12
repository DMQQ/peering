mod support;

use peering_net::identity::{HostIdentity, IdentityError, DEVICE_ID_SECRET_NAME, KEY_SECRET_NAME};
use peering_wire::relay_proof::ProofSigner;
use ring::signature::{UnparsedPublicKey, ECDSA_P256_SHA256_ASN1};
use support::MemorySecrets;

fn load(store: &MemorySecrets) -> HostIdentity {
    HostIdentity::load(store, "Studio Mac").expect("identity loads")
}

#[test]
fn key_and_device_id_persist_across_loads() {
    let store = MemorySecrets::default();
    let first = load(&store);
    let second = load(&store);
    assert_eq!(first.public_key_bytes(), second.public_key_bytes());
    assert_eq!(first.private_key_pkcs8(), second.private_key_pkcs8());
    assert_eq!(first.device_id(), second.device_id());
}

#[test]
fn a_stored_key_is_loaded_and_never_replaced() {
    let original = load(&MemorySecrets::default());
    let store = MemorySecrets::default()
        .with_value(KEY_SECRET_NAME, original.private_key_pkcs8())
        .with_value(DEVICE_ID_SECRET_NAME, original.device_id().as_bytes());
    let reloaded = load(&store);
    assert_eq!(reloaded.public_key_bytes(), original.public_key_bytes());
    assert_eq!(store.value(KEY_SECRET_NAME).as_deref(), Some(original.private_key_pkcs8()));
}

#[test]
fn a_failed_key_read_is_an_error_and_mints_no_new_key() {
    let original = load(&MemorySecrets::default());
    let store = MemorySecrets::default()
        .with_value(KEY_SECRET_NAME, original.private_key_pkcs8())
        .with_value(DEVICE_ID_SECRET_NAME, original.device_id().as_bytes())
        .refusing_reads_of(KEY_SECRET_NAME);
    let result = HostIdentity::load(&store, "Studio Mac");
    assert!(matches!(result, Err(IdentityError::KeyUnreadable(_))));
    assert_eq!(store.value(KEY_SECRET_NAME).as_deref(), Some(original.private_key_pkcs8()));
}

#[test]
fn a_failed_device_id_read_is_an_error_and_writes_nothing() {
    let key = load(&MemorySecrets::default());
    let store = MemorySecrets::default()
        .with_value(KEY_SECRET_NAME, key.private_key_pkcs8())
        .refusing_reads_of(DEVICE_ID_SECRET_NAME);
    let result = HostIdentity::load(&store, "Studio Mac");
    assert!(matches!(result, Err(IdentityError::DeviceIdUnreadable(_))));
    assert_eq!(store.value(DEVICE_ID_SECRET_NAME), None);
}

#[test]
fn a_refused_key_write_is_an_error_not_a_silent_identity() {
    let store = MemorySecrets::default()
        .with_value(DEVICE_ID_SECRET_NAME, b"0F6B2C1E-8D4A-4B7E-9C3D-1A2B3C4D5E6F")
        .refusing_writes();
    let result = HostIdentity::load(&store, "Studio Mac");
    assert!(matches!(result, Err(IdentityError::KeyNotStored)));
}

#[test]
fn a_refused_device_id_write_is_an_error() {
    let key = load(&MemorySecrets::default());
    let store = MemorySecrets::default()
        .with_value(KEY_SECRET_NAME, key.private_key_pkcs8())
        .refusing_writes();
    let result = HostIdentity::load(&store, "Studio Mac");
    assert!(matches!(result, Err(IdentityError::DeviceIdNotStored)));
}

#[test]
fn a_stored_device_id_is_reused() {
    let store = MemorySecrets::default().with_value(DEVICE_ID_SECRET_NAME, b"0F6B2C1E-8D4A-4B7E-9C3D-1A2B3C4D5E6F");
    let identity = load(&store);
    assert_eq!(identity.device_id(), "0F6B2C1E-8D4A-4B7E-9C3D-1A2B3C4D5E6F");
}

#[test]
fn a_new_device_id_is_an_uppercase_version_four_uuid() {
    let identity = load(&MemorySecrets::default());
    let id = identity.device_id();
    assert_eq!(id.len(), 36);
    assert!(id.chars().all(|c| c == '-' || c.is_ascii_digit() || ('A'..='F').contains(&c)));
    assert_eq!(&id[14..15], "4");
    assert!(matches!(&id[19..20], "8" | "9" | "A" | "B"));
}

#[test]
fn the_public_point_is_65_bytes_starting_with_0x04() {
    let point = load(&MemorySecrets::default()).public_key_bytes();
    assert_eq!(point.len(), 65);
    assert_eq!(point[0], 0x04);
}

#[test]
fn a_signature_verifies_against_the_public_point() {
    let identity = load(&MemorySecrets::default());
    let message = b"peeringd-host-registration-v1\nid\n1700000000";
    let signature = identity.sign(message).expect("signs");
    let verifier = UnparsedPublicKey::new(&ECDSA_P256_SHA256_ASN1, identity.public_key_bytes());
    verifier.verify(message, &signature).expect("signature verifies");
    assert!(verifier.verify(b"other", &signature).is_err());
}

#[test]
fn the_proof_signer_reports_the_same_key_and_a_verifiable_signature() {
    let identity = load(&MemorySecrets::default());
    let message = b"payload";
    let signer: &dyn ProofSigner = &identity;
    assert_eq!(signer.public_key(), identity.public_key_bytes());
    let verifier = UnparsedPublicKey::new(&ECDSA_P256_SHA256_ASN1, identity.public_key_bytes());
    verifier.verify(message, &signer.sign(message)).expect("signature verifies");
}

#[test]
fn each_start_mints_a_new_certificate_over_the_same_key() {
    let store = MemorySecrets::default();
    let first = load(&store);
    let second = load(&store);
    assert_ne!(first.certificate_der(), second.certificate_der());
    assert_eq!(first.public_key_bytes(), second.public_key_bytes());
}

#[test]
fn the_certificate_follows_the_protocol_template() {
    let identity = load(&MemorySecrets::default());
    let (rest, certificate) =
        x509_parser::parse_x509_certificate(identity.certificate_der()).expect("certificate parses");
    assert!(rest.is_empty());
    assert_eq!(certificate.version().0, 2);

    let common_name = certificate.subject().iter_common_name().next().expect("common name");
    assert_eq!(common_name.as_str().expect("utf8"), "Studio Mac");
    let organisation = certificate.subject().iter_organization().next().expect("organisation");
    assert_eq!(organisation.as_str().expect("utf8"), "Peering");
    assert_eq!(certificate.issuer(), certificate.subject());

    let constraints = certificate.basic_constraints().expect("parses").expect("present");
    assert!(constraints.critical);
    assert!(!constraints.value.ca);

    let usage = certificate.key_usage().expect("parses").expect("present");
    assert!(usage.value.digital_signature());

    let usages = certificate.extended_key_usage().expect("parses").expect("present");
    assert!(usages.value.server_auth);
    assert!(!usages.value.client_auth);

    let key = certificate.public_key();
    assert_eq!(key.subject_public_key.data.as_ref(), identity.public_key_bytes().as_slice());

    let now = time::OffsetDateTime::now_utc().unix_timestamp();
    let validity = certificate.validity();
    assert!(validity.not_before.timestamp() <= now - 3500);
    let ten_years = 3650 * 24 * 3600;
    let lifetime = validity.not_after.timestamp() - now;
    assert!((ten_years - 3600..=ten_years + 3600).contains(&lifetime));
}
