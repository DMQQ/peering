//! The TCP listener: each accepted connection completes TLS, then is served with the peer's certificate key.

use std::sync::Arc;
use std::time::Duration;

use peering_net::tls::HostTls;
use tokio::net::TcpListener;
use tokio::task::spawn_local;

use super::connection::serve;
use super::shared::Shared;
use super::{HostProfile, PeerInfo};

const ACCEPT_RETRY: Duration = Duration::from_millis(100);

pub async fn serve_listener(shared: Shared, profile: Arc<HostProfile>, tls: Arc<HostTls>, listener: TcpListener) {
    loop {
        let Ok((stream, _address)) = listener.accept().await else {
            // Accept fails when the process is out of descriptors; waiting lets connections close before the next try.
            tokio::time::sleep(ACCEPT_RETRY).await;
            continue;
        };
        let shared = shared.clone();
        let profile = profile.clone();
        let tls = tls.clone();
        spawn_local(async move {
            // A client that fails TLS never reaches the protocol.
            let Ok(accepted) = tls.accept(stream).await else {
                return;
            };
            let peer = PeerInfo { public_key: Some(accepted.client_public_key), via_relay: false, video_token: None };
            serve(shared, profile, accepted.stream, peer).await;
        });
    }
}
