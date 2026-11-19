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

/// Like `quiche_conn_send`, but also says how long to hold the packet before writing it, which is
/// how quiche paces a burst over the round trip. quiche's own C API reports a send time of zero on
/// Apple platforms (its `std_time_to_c` is unimplemented there), so pacing is lost without this.
///
/// Returns the packet's length, or a negative value when nothing was written (-1 when there is
/// simply nothing to send). `to` receives the destination, `delay_nanos` the wait before sending it.
///
/// # Safety
/// `conn` must be a live `quiche_conn`, `out` valid for `out_len` bytes, the others writable.
#[no_mangle]
pub unsafe extern "C" fn peering_quic_conn_send(
    conn: *mut quiche::Connection,
    out: *mut u8,
    out_len: usize,
    to: *mut libc::sockaddr_storage,
    to_len: *mut libc::socklen_t,
    delay_nanos: *mut u64,
) -> isize {
    let conn = &mut *conn;
    let buffer = std::slice::from_raw_parts_mut(out, out_len);
    match conn.send(buffer) {
        Ok((written, info)) => {
            *to_len = write_address(info.to, &mut *to);
            let wait = info.at.saturating_duration_since(std::time::Instant::now());
            *delay_nanos = u64::try_from(wait.as_nanos()).unwrap_or(u64::MAX);
            written as isize
        }
        // QUICHE_ERR_DONE when there is nothing to send; any other failure is reported as one negative value, which the caller treats the same way.
        Err(quiche::Error::Done) => -1,
        Err(_) => -10,
    }
}

fn write_address(address: std::net::SocketAddr, out: &mut libc::sockaddr_storage) -> libc::socklen_t {
    use std::net::SocketAddr;
    match address {
        SocketAddr::V4(v4) => {
            let raw = out as *mut libc::sockaddr_storage as *mut libc::sockaddr_in;
            // SAFETY: sockaddr_storage is large and aligned enough for any sockaddr.
            unsafe {
                *raw = std::mem::zeroed();
                (*raw).sin_len = std::mem::size_of::<libc::sockaddr_in>() as u8;
                (*raw).sin_family = libc::AF_INET as libc::sa_family_t;
                (*raw).sin_port = v4.port().to_be();
                (*raw).sin_addr = libc::in_addr { s_addr: u32::from_ne_bytes(v4.ip().octets()) };
            }
            std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t
        }
        SocketAddr::V6(v6) => {
            let raw = out as *mut libc::sockaddr_storage as *mut libc::sockaddr_in6;
            // SAFETY: as above.
            unsafe {
                *raw = std::mem::zeroed();
                (*raw).sin6_len = std::mem::size_of::<libc::sockaddr_in6>() as u8;
                (*raw).sin6_family = libc::AF_INET6 as libc::sa_family_t;
                (*raw).sin6_port = v6.port().to_be();
                (*raw).sin6_addr = libc::in6_addr { s6_addr: v6.ip().octets() };
                (*raw).sin6_scope_id = v6.scope_id();
                (*raw).sin6_flowinfo = v6.flowinfo();
            }
            std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t
        }
    }
}
