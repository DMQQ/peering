mod support;

use std::sync::Arc;

use peering_net::identity::HostIdentity;
use peering_net::tls::{AcceptedClient, HostTls, TlsError};
use rustls::version::{TLS12, TLS13};
use rustls::{ClientConfig, SupportedProtocolVersion};
use rustls_pki_types::ServerName;
use support::client::{client_config, self_signed_client, ClientCredentials};
use support::MemorySecrets;
use tokio::io::DuplexStream;
use tokio_rustls::client::TlsStream as ClientTlsStream;
use tokio_rustls::TlsConnector;
use x509_parser::prelude::{FromDer, X509Certificate};

type ServerResult = Result<AcceptedClient<DuplexStream>, TlsError>;
type ClientResult = std::io::Result<ClientTlsStream<DuplexStream>>;

fn host() -> (HostIdentity, HostTls) {
    let identity = HostIdentity::load(&MemorySecrets::default(), "Studio Mac").expect("identity loads");
    let tls = HostTls::new(&identity).expect("server config builds");
    (identity, tls)
}

async fn handshake(
    tls: &HostTls,
    client: ClientConfig,
) -> (ServerResult, ClientResult) {
    let (server_side, client_side) = tokio::io::duplex(64 * 1024);
    let connector = TlsConnector::from(Arc::new(client));
    let server_name = ServerName::try_from("peering.test").expect("server name");
    let (server, client) = tokio::join!(
        tls.accept(server_side),
        connector.connect(server_name, client_side)
    );
    (server, client)
}

fn point_of(certificate_der: &[u8]) -> Vec<u8> {
    let (_, certificate) = X509Certificate::from_der(certificate_der).expect("certificate parses");
    certificate.public_key().subject_public_key.data.to_vec()
}

fn modern_client(credentials: &ClientCredentials) -> ClientConfig {
    client_config(&[&TLS13], Some(credentials))
}

#[tokio::test]
async fn a_pinned_handshake_negotiates_tls13_and_exposes_both_points() {
    let (identity, tls) = host();
    let credentials = self_signed_client();
    let (server, client) = handshake(&tls, modern_client(&credentials)).await;

    let accepted = server.expect("server accepts the client");
    assert_eq!(accepted.client_public_key, credentials.public_point);
    assert_eq!(accepted.client_public_key.len(), 65);

    let client = client.expect("client completes the handshake");
    let (_, connection) = client.get_ref();
    assert_eq!(connection.protocol_version(), Some(rustls::ProtocolVersion::TLSv1_3));
    let presented = connection.peer_certificates().expect("server certificate")[0].clone();
    assert_eq!(point_of(presented.as_ref()), identity.public_key_bytes());
}

#[tokio::test]
async fn a_tls12_only_client_is_refused() {
    let (_identity, tls) = host();
    let credentials = self_signed_client();
    let versions: &[&'static SupportedProtocolVersion] = &[&TLS12];
    let (server, client) = handshake(&tls, client_config(versions, Some(&credentials))).await;
    assert!(server.is_err());
    assert!(client.is_err());
}

#[tokio::test]
async fn a_client_without_a_certificate_is_refused() {
    let (_identity, tls) = host();
    let (server, _client) = handshake(&tls, client_config(&[&TLS13], None)).await;
    assert!(server.is_err());
}

#[tokio::test]
async fn the_relay_path_runs_the_same_handshake() {
    let (identity, tls) = host();
    let credentials = self_signed_client();
    let (server_side, client_side) = tokio::io::duplex(64 * 1024);
    let connector = TlsConnector::from(Arc::new(modern_client(&credentials)));
    let server_name = ServerName::try_from("relay.peering.test").expect("server name");
    let (server, client) = tokio::join!(
        tls.relay_accept(server_side),
        connector.connect(server_name, client_side)
    );
    assert_eq!(server.expect("accepts").client_public_key, credentials.public_point);
    let client = client.expect("completes");
    let presented = client.get_ref().1.peer_certificates().expect("certificate")[0].clone();
    assert_eq!(point_of(presented.as_ref()), identity.public_key_bytes());
}
