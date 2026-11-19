//! The spike's evidence, end to end in one process: two Peering ends with keychain-style identities,
//! a relay that routes by a token in front of each datagram, a stream, datagrams, and a move from
//! the relay to a direct path without a new handshake.

use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

use boring::asn1::Asn1Time;
use boring::bn::{BigNum, BigNumContext};
use boring::ec::{EcGroup, EcKey, PointConversionForm};
use boring::hash::MessageDigest;
use boring::nid::Nid;
use boring::pkey::PKey;
use boring::x509::{X509Builder, X509NameBuilder};

const TOKEN_LEN: usize = 16;

struct Identity {
    certificate: Vec<u8>,
    x963: Vec<u8>,
}

fn identity(name: &str) -> Identity {
    let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap();
    let key = EcKey::generate(&group).unwrap();
    let mut context = BigNumContext::new().unwrap();
    let mut x963 = key.public_key().to_bytes(&group, PointConversionForm::UNCOMPRESSED, &mut context).unwrap();
    x963.extend(key.private_key().to_vec_padded(32).unwrap());
    let pkey = PKey::from_ec_key(key).unwrap();

    let mut subject = X509NameBuilder::new().unwrap();
    subject.append_entry_by_text("CN", name).unwrap();
    let subject = subject.build();
    let mut builder = X509Builder::new().unwrap();
    builder.set_version(2).unwrap();
    builder.set_serial_number(&BigNum::from_u32(1).unwrap().to_asn1_integer().unwrap()).unwrap();
    builder.set_subject_name(&subject).unwrap();
    builder.set_issuer_name(&subject).unwrap();
    builder.set_pubkey(&pkey).unwrap();
    builder.set_not_before(&Asn1Time::days_from_now(0).unwrap()).unwrap();
    builder.set_not_after(&Asn1Time::days_from_now(365).unwrap()).unwrap();
    builder.sign(&pkey, MessageDigest::sha256()).unwrap();
    Identity { certificate: builder.build().to_der().unwrap(), x963 }
}

fn config(identity: &Identity) -> Box<quiche::Config> {
    let raw = unsafe {
        peering_quic::peering_quic_config_new(
            identity.certificate.as_ptr(), identity.certificate.len(),
            identity.x963.as_ptr(), identity.x963.len(),
        )
    };
    assert!(!raw.is_null(), "the keychain-form identity is accepted");
    let mut config = unsafe { Box::from_raw(raw) };
    config.set_application_protos(&[b"peering/21"]).unwrap();
    config.set_max_idle_timeout(10_000);
    config.set_initial_max_data(10_000_000);
    config.set_initial_max_stream_data_bidi_local(1_000_000);
    config.set_initial_max_stream_data_bidi_remote(1_000_000);
    config.set_initial_max_streams_bidi(16);
    config.enable_dgram(true, 1024, 1024);
    config.set_active_connection_id_limit(4);
    config
}

/// One end: a socket, and what it prepends when sending to the relay.
struct End {
    socket: UdpSocket,
    token: [u8; TOKEN_LEN],
    relay: SocketAddr,
}

impl End {
    fn local(&self) -> SocketAddr { self.socket.local_addr().unwrap() }

    fn flush(&self, conn: &mut quiche::Connection) {
        let mut out = [0u8; 1500];
        loop {
            match conn.send(&mut out) {
                Ok((len, info)) => {
                    if info.to == self.relay {
                        let mut framed = self.token.to_vec();
                        framed.extend_from_slice(&out[..len]);
                        self.socket.send_to(&framed, info.to).unwrap();
                    } else {
                        self.socket.send_to(&out[..len], info.to).unwrap();
                    }
                }
                Err(quiche::Error::Done) => break,
                Err(error) => panic!("send failed: {error:?}"),
            }
        }
    }

    fn drain(&self, conn: &mut quiche::Connection) {
        let mut buffer = [0u8; 2048];
        while let Ok((len, from)) = self.socket.recv_from(&mut buffer) {
            let info = quiche::RecvInfo { from, to: self.local() };
            let _ = conn.recv(&mut buffer[..len], info);
        }
    }
}

/// Routes `token || packet` to the other end's last address, stripping the token, as the real relay does.
struct Relay {
    socket: UdpSocket,
    seen: [Option<SocketAddr>; 2],
}

impl Relay {
    fn pump(&mut self) {
        let mut buffer = [0u8; 2048];
        while let Ok((len, from)) = self.socket.recv_from(&mut buffer) {
            let side = buffer[0] as usize;
            self.seen[side] = Some(from);
            if let Some(to) = self.seen[1 - side] {
                self.socket.send_to(&buffer[TOKEN_LEN..len], to).unwrap();
            }
        }
    }
}

fn socket() -> UdpSocket {
    let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    socket.set_nonblocking(true).unwrap();
    socket
}

#[test]
fn a_session_over_the_relay_moves_to_the_direct_path_without_a_new_handshake() {
    let relay_socket = socket();
    let relay_address = relay_socket.local_addr().unwrap();
    let mut relay = Relay { socket: relay_socket, seen: [None, None] };

    let phone = End { socket: socket(), token: [0; TOKEN_LEN], relay: relay_address };
    let mac = End { socket: socket(), token: [1; TOKEN_LEN], relay: relay_address };
    // The Mac binds first, as it does with the real relay, so the relay knows where it is.
    mac.socket.send_to(&mac.token, relay_address).unwrap();
    std::thread::sleep(Duration::from_millis(5));
    relay.pump();

    let phone_identity = identity("phone");
    let mac_identity = identity("mac");
    let mut phone_config = config(&phone_identity);
    let mut mac_config = config(&mac_identity);

    let started = Instant::now();
    let scid = quiche::ConnectionId::from_ref(&[7; 16]);
    let mut client = quiche::connect(None, &scid, phone.local(), relay_address, &mut phone_config).unwrap();
    let mut server: Option<quiche::Connection> = None;

    let mut step = |client: &mut quiche::Connection, server: &mut Option<quiche::Connection>, relay: &mut Relay| {
        phone.flush(client);
        std::thread::sleep(Duration::from_millis(1));
        relay.pump();
        let mut buffer = [0u8; 2048];
        while let Ok((len, from)) = mac.socket.recv_from(&mut buffer) {
            if server.is_none() {
                let header = quiche::Header::from_slice(&mut buffer[..len], quiche::MAX_CONN_ID_LEN).unwrap();
                let id = quiche::ConnectionId::from_ref(&[9; 16]);
                *server = Some(quiche::accept(&id, None, mac.local(), from, &mut mac_config).unwrap());
                let _ = header;
            }
            let info = quiche::RecvInfo { from, to: mac.local() };
            let _ = server.as_mut().unwrap().recv(&mut buffer[..len], info);
        }
        if let Some(server) = server.as_mut() { mac.flush(server); }
        std::thread::sleep(Duration::from_millis(1));
        relay.pump();
        phone.drain(client);
    };

    while !client.is_established() || server.as_ref().map(|s| !s.is_established()).unwrap_or(true) {
        step(&mut client, &mut server, &mut relay);
        assert!(started.elapsed() < Duration::from_secs(5), "handshake finishes");
    }
    eprintln!("handshake through the relay took {:?}", started.elapsed());

    // Each end sees the other's certificate, which is what the pin is checked against.
    assert_eq!(client.peer_cert(), Some(mac_identity.certificate.as_slice()));
    assert_eq!(server.as_ref().unwrap().peer_cert(), Some(phone_identity.certificate.as_slice()));

    client.stream_send(0, b"hello over a stream", true).unwrap();
    client.dgram_send(b"a datagram").unwrap();
    step(&mut client, &mut server, &mut relay);
    step(&mut client, &mut server, &mut relay);
    let server_conn = server.as_mut().unwrap();
    let mut buffer = [0u8; 64];
    let (read, fin) = server_conn.stream_recv(0, &mut buffer).unwrap();
    assert_eq!(&buffer[..read], b"hello over a stream");
    assert!(fin);
    let len = server_conn.dgram_recv(&mut buffer).unwrap();
    assert_eq!(&buffer[..len], b"a datagram");

    // A new path needs a connection id the old one never used, so each end hands the other spares.
    for n in 1..3u8 {
        server.as_mut().unwrap().new_scid(&quiche::ConnectionId::from_vec(vec![0x90 + n; 16]), u128::from(n), false).unwrap();
        client.new_scid(&quiche::ConnectionId::from_vec(vec![0x70 + n; 16]), u128::from(n) + 100, false).unwrap();
    }
    step(&mut client, &mut server, &mut relay);
    step(&mut client, &mut server, &mut relay);

    // The punch found the Mac's own address: the phone moves there, keeping the connection.
    let direct = mac.local();
    client.probe_path(phone.local(), direct).unwrap();
    let moved = Instant::now();
    while !client.is_path_validated(phone.local(), direct).unwrap_or(false) {
        step(&mut client, &mut server, &mut relay);
        assert!(moved.elapsed() < Duration::from_secs(3), "the direct path validates");
    }
    client.migrate(phone.local(), direct).unwrap();
    client.dgram_send(b"after the move").unwrap();
    step(&mut client, &mut server, &mut relay);
    step(&mut client, &mut server, &mut relay);
    let len = server.as_mut().unwrap().dgram_recv(&mut buffer).unwrap();
    assert_eq!(&buffer[..len], b"after the move");
    eprintln!("relay to direct took {:?}", moved.elapsed());
    assert!(client.is_established(), "same connection, no new handshake");
}
