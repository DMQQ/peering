//! Pinned mutual TLS 1.3 for the host. The host presents its identity certificate and requires a client certificate.
//! Trust is decided after the handshake, by pin, so the verifier accepts any client key.

mod client_verifier;

use std::sync::Arc;

use rustls::crypto::ring::default_provider;
use rustls::crypto::ring::sign::any_supported_type;
use rustls::sign::{CertifiedKey, SingleCertAndKey};
use rustls::version::TLS13;
use rustls::{ServerConfig, ServerConnection};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_rustls::server::TlsStream;
use tokio_rustls::TlsAcceptor;
use x509_parser::prelude::{FromDer, X509Certificate};

use crate::identity::HostIdentity;
use client_verifier::AnyClientCertificate;

#[derive(Debug, thiserror::Error)]
pub enum TlsError {
    #[error("the TLS server configuration could not be built: {0}")]
    Configuration(String),
    #[error("the TLS handshake failed: {0}")]
    Handshake(std::io::Error),
    #[error("the client certificate does not carry a usable public key")]
    ClientKeyMissing,
}

pub struct AcceptedClient<S> {
    pub stream: TlsStream<S>,
    pub client_public_key: Vec<u8>,
}

pub struct HostTls {
    acceptor: TlsAcceptor,
}

impl HostTls {
    pub fn new(identity: &HostIdentity) -> Result<Self, TlsError> {
        let certificate = CertificateDer::from(identity.certificate_der().to_vec());
        // Borrowed, so no second copy of the private key is left behind that nothing would wipe.
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(identity.private_key_pkcs8()));
        let signing_key = any_supported_type(&key).map_err(|error| TlsError::Configuration(error.to_string()))?;
        let certified = CertifiedKey::new(vec![certificate], signing_key);
        let config = ServerConfig::builder_with_provider(Arc::new(default_provider()))
            .with_protocol_versions(&[&TLS13])
            .map_err(|error| TlsError::Configuration(error.to_string()))?
            .with_client_cert_verifier(Arc::new(AnyClientCertificate::new()))
            .with_cert_resolver(Arc::new(SingleCertAndKey::from(certified)));
        Ok(Self {
            acceptor: TlsAcceptor::from(Arc::new(config)),
        })
    }

    pub async fn accept<S>(&self, stream: S) -> Result<AcceptedClient<S>, TlsError>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let stream = self.acceptor.accept(stream).await.map_err(TlsError::Handshake)?;
        let client_public_key = peer_public_key(stream.get_ref().1).ok_or(TlsError::ClientKeyMissing)?;
        Ok(AcceptedClient {
            stream,
            client_public_key,
        })
    }

    /// The same handshake, for a stream on which the relay token has already been written.
    pub async fn relay_accept<S>(&self, stream: S) -> Result<AcceptedClient<S>, TlsError>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        self.accept(stream).await
    }
}

/// The 65 byte uncompressed point of the client's leaf certificate, or None when there is no certificate or it does not parse.
pub fn peer_public_key(connection: &ServerConnection) -> Option<Vec<u8>> {
    let leaf = connection.peer_certificates()?.first()?;
    let (_, certificate) = X509Certificate::from_der(leaf.as_ref()).ok()?;
    Some(certificate.public_key().subject_public_key.data.to_vec())
}
