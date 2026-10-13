use std::sync::Arc;

use rcgen::{CertificateParams, KeyPair};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::ring::default_provider;
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, WebPkiSupportedAlgorithms};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, Error, SignatureScheme, SupportedProtocolVersion};

#[derive(Debug)]
pub struct AcceptAnyServer {
    algorithms: WebPkiSupportedAlgorithms,
}

impl ServerCertVerifier for AcceptAnyServer {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls12_signature(message, cert, dss, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![SignatureScheme::ECDSA_NISTP256_SHA256]
    }
}

pub struct ClientCredentials {
    pub certificate: CertificateDer<'static>,
    pub key: PrivateKeyDer<'static>,
    pub public_point: Vec<u8>,
}

pub fn self_signed_client() -> ClientCredentials {
    let key = KeyPair::generate().expect("generates a P-256 key");
    let params = CertificateParams::new(vec!["client.peering.test".to_owned()]).expect("params");
    let certificate = params.self_signed(&key).expect("self signs");
    ClientCredentials {
        certificate: certificate.der().clone(),
        key: PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der())),
        public_point: key.public_key_raw().to_vec(),
    }
}

pub fn client_config(
    versions: &[&'static SupportedProtocolVersion],
    credentials: Option<&ClientCredentials>,
) -> ClientConfig {
    let provider = default_provider();
    let algorithms = provider.signature_verification_algorithms;
    let builder = ClientConfig::builder_with_provider(Arc::new(provider))
        .with_protocol_versions(versions)
        .expect("versions")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyServer { algorithms }));
    match credentials {
        Some(credentials) => builder
            .with_client_auth_cert(vec![credentials.certificate.clone()], credentials.key.clone_key())
            .expect("client certificate"),
        None => builder.with_no_client_auth(),
    }
}
