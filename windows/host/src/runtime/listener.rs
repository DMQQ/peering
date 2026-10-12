//! The TCP listener: each accepted connection completes TLS, then is served with the peer's certificate key.

use std::sync::Arc;
use std::time::Duration;

use peering_net::socket::disable_nagle;
use peering_net::tls::HostTls;
use tokio::net::TcpListener;
use tokio::task::spawn_local;

use super::connection::serve_counted;
use super::pre_auth::{PreAuthGate, MAXIMUM_PRE_AUTH_CONNECTIONS};
use super::shared::Shared;
use super::{HostProfile, PeerInfo};

const ACCEPT_RETRY: Duration = Duration::from_millis(100);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

pub async fn serve_listener(shared: Shared, profile: Arc<HostProfile>, tls: Arc<HostTls>, listener: TcpListener) {
    let gate = PreAuthGate::new(MAXIMUM_PRE_AUTH_CONNECTIONS);
    loop {
        let Ok((stream, _address)) = listener.accept().await else {
            // Accept fails when the process is out of descriptors; waiting lets connections close before the next try.
            tokio::time::sleep(ACCEPT_RETRY).await;
            continue;
        };
        // A host that is switched off refuses the connection by closing it at once.
        if !shared.lock().hosting {
            continue;
        }
        // Only latency suffers when the option cannot be set, so the connection is still served.
        let _nagle = disable_nagle(&stream);
        let Some(permit) = gate.enter() else {
            continue;
        };
        let shared = shared.clone();
        let profile = profile.clone();
        let tls = tls.clone();
        spawn_local(async move {
            // A client that fails TLS never reaches the protocol.
            let Ok(Ok(accepted)) = tokio::time::timeout(HANDSHAKE_TIMEOUT, tls.accept(stream)).await else {
                return;
            };
            let peer = PeerInfo {
                public_key: Some(accepted.client_public_key),
                via_relay: false,
                video_token: None,
                video_endpoint: None,
            };
            serve_counted(shared, profile, accepted.stream, peer, Some(permit)).await;
        });
    }
}
