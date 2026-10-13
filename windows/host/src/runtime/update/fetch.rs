//! One HTTPS request to GitHub's API, on the calling thread. Unverified against the real service: the parts that decide anything
//! (the HTTP answer, the list of releases) are `peering_core::http` and `peering_core::update`, which are tested.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use peering_core::http::{body_of, MAXIMUM_RESPONSE_BYTES};
use rustls::crypto::ring::default_provider;
use rustls::pki_types::ServerName;
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};

use super::ReleaseSource;

const HOST: &str = "api.github.com";
const PATH: &str = "/repos/DMQQ/peering/releases?per_page=30";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const READ_TIMEOUT: Duration = Duration::from_secs(15);

/// GitHub's list of the repository's releases.
pub struct GithubReleases {
    /// Named in the request, as GitHub's API asks every client to.
    pub user_agent: String,
}

impl ReleaseSource for GithubReleases {
    fn fetch(&self) -> Result<String, String> {
        let answer = self.get().map_err(|error| error.to_string())?;
        let body = body_of(&answer).map_err(|error| error.to_string())?;
        String::from_utf8(body).map_err(|_| "the answer is not text".to_owned())
    }
}

impl GithubReleases {
    fn get(&self) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let mut roots = RootCertStore::empty();
        roots.roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let config = ClientConfig::builder_with_provider(Arc::new(default_provider()))
            .with_safe_default_protocol_versions()?
            .with_root_certificates(roots)
            .with_no_client_auth();
        let address = (HOST, 443).to_socket_addrs()?.next().ok_or("the address of GitHub could not be found")?;
        let tcp = TcpStream::connect_timeout(&address, CONNECT_TIMEOUT)?;
        tcp.set_read_timeout(Some(READ_TIMEOUT))?;
        tcp.set_write_timeout(Some(READ_TIMEOUT))?;
        let mut tls = StreamOwned::new(ClientConnection::new(Arc::new(config), ServerName::try_from(HOST)?)?, tcp);
        let request = format!(
            "GET {PATH} HTTP/1.1\r\nHost: {HOST}\r\nUser-Agent: {}\r\nAccept: application/vnd.github+json\r\nConnection: close\r\n\r\n",
            self.user_agent
        );
        tls.write_all(request.as_bytes())?;
        let mut answer = Vec::new();
        // The server closes the connection when it is done, often without the TLS goodbye, which reads as an early end of file.
        match (&mut tls).take(MAXIMUM_RESPONSE_BYTES as u64 + 1).read_to_end(&mut answer) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof && !answer.is_empty() => {}
            Err(error) => return Err(error.into()),
        }
        if answer.len() > MAXIMUM_RESPONSE_BYTES {
            return Err("the answer is larger than a list of releases".into());
        }
        Ok(answer)
    }
}
