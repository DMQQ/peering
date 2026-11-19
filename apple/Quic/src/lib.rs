//! quiche's C API, plus the one thing it lacks for Peering: a configuration whose TLS identity comes
//! from memory (the keychain's key and certificate) instead of PEM files on disk.

use std::slice;

use boring::bn::BigNumContext;
use boring::ec::{EcGroup, EcKey, EcPoint};
use boring::nid::Nid;
use boring::pkey::PKey;
use boring::ssl::{SslContextBuilder, SslMethod, SslVerifyMode};
use boring::x509::X509;

pub use quiche;

/// A configuration for one end of a Peering connection.
///
/// `certificate` is DER. `private_key` is a P-256 key in the keychain's external form (X9.63:
/// `04 || X || Y || K`). The TLS layer accepts any certificate: each end checks the other's against
/// its pin once the handshake is done, as the TCP sessions always have.
///
/// Returns null when the key or certificate cannot be read. The result is freed with
/// `quiche_config_free`.
///
/// # Safety
/// The pointers must be valid for the lengths given.
#[no_mangle]
pub unsafe extern "C" fn peering_quic_config_new(
    certificate: *const u8,
    certificate_len: usize,
    private_key: *const u8,
    private_key_len: usize,
) -> *mut quiche::Config {
    let certificate = slice::from_raw_parts(certificate, certificate_len);
    let private_key = slice::from_raw_parts(private_key, private_key_len);
    match make_config(certificate, private_key) {
        Some(config) => Box::into_raw(Box::new(config)),
        None => std::ptr::null_mut(),
    }
}

fn make_config(certificate: &[u8], private_key: &[u8]) -> Option<quiche::Config> {
    let key = p256_key(private_key)?;
    let certificate = X509::from_der(certificate).ok()?;

    let mut tls = SslContextBuilder::new(SslMethod::tls()).ok()?;
    tls.set_certificate(&certificate).ok()?;
    tls.set_private_key(&key).ok()?;
    tls.check_private_key().ok()?;
    // Self-signed by design: the pin, not a CA, says who the peer is. A client certificate is
    // asked for so the Mac learns the phone's key the same way the phone learns the Mac's.
    tls.set_verify_callback(SslVerifyMode::PEER, |_, _| true);

    // Never `verify_peer` on the result: quiche implements it by resetting the verify mode with no
    // callback, which stops the Mac asking for the phone's certificate at all.
    quiche::Config::with_boring_ssl_ctx_builder(quiche::PROTOCOL_VERSION, tls).ok()
}

fn p256_key(x963: &[u8]) -> Option<PKey<boring::pkey::Private>> {
    // 1 + 32 + 32 public, then 32 private.
    if x963.len() != 97 || x963[0] != 0x04 {
        return None;
    }
    let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).ok()?;
    let mut context = BigNumContext::new().ok()?;
    let public = EcPoint::from_bytes(&group, &x963[..65], &mut context).ok()?;
    let private = boring::bn::BigNum::from_slice(&x963[65..]).ok()?;
    let key = EcKey::from_private_components(&group, &private, &public).ok()?;
    key.check_key().ok()?;
    PKey::from_ec_key(key).ok()
}
