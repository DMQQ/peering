use super::*;
use crate::runtime::outbound::{outbound, OutboundReceiver};
use tokio::net::TcpListener;
use tokio::task::LocalSet;

fn get(id: u32, port: u16) -> PreviewProxyCommand {
    let request = PreviewProxyRequest { id, port, method: "GET".to_owned(), target: "/".to_owned(), headers: Vec::new(), body: None };
    PreviewProxyCommand::Fetch { request }
}

async fn events_until_final(frames: &mut OutboundReceiver<Frame>) -> Vec<PreviewProxyEvent> {
    let mut events = Vec::new();
    while let Some(frame) = frames.recv().await {
        let event: PreviewProxyEvent = serde_json::from_slice(&frame.payload).expect("an event");
        let last = matches!(event, PreviewProxyEvent::End { .. } | PreviewProxyEvent::Failure { .. });
        events.push(event);
        if last {
            break;
        }
    }
    events
}

#[tokio::test]
async fn a_loopback_server_is_fetched_and_streamed_back() {
    LocalSet::new()
        .run_until(async {
            let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.expect("binds");
            let port = listener.local_addr().expect("an address").port();
            spawn_local(async move {
                let (mut socket, _) = listener.accept().await.expect("accepts");
                let mut request = [0u8; 1024];
                let _read = socket.read(&mut request).await;
                let answer = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nhi";
                socket.write_all(answer).await.expect("writes");
            });
            let (sender, mut frames) = outbound();
            PreviewTransfers::default().handle(get(3, port), 51515, &sender);
            let events = events_until_final(&mut frames).await;
            assert!(matches!(&events[0], PreviewProxyEvent::Head { id: 3, status: 200, .. }));
            assert_eq!(events[1], PreviewProxyEvent::Body { id: 3, data: b"hi".to_vec() });
            assert_eq!(events[2], PreviewProxyEvent::End { id: 3, truncated: false });
        })
        .await;
}

#[tokio::test]
async fn a_port_with_nothing_listening_is_reported_as_such() {
    LocalSet::new()
        .run_until(async {
            let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.expect("binds");
            let port = listener.local_addr().expect("an address").port();
            drop(listener);
            let (sender, mut frames) = outbound();
            PreviewTransfers::default().handle(get(9, port), 51515, &sender);
            let events = events_until_final(&mut frames).await;
            assert_eq!(events, [PreviewProxyEvent::Failure { id: 9, reason: PreviewFailure::NotListening }]);
        })
        .await;
}

#[tokio::test]
async fn the_hosts_own_port_is_refused_without_dialling() {
    LocalSet::new()
        .run_until(async {
            let (sender, mut frames) = outbound();
            PreviewTransfers::default().handle(get(1, 6000), 6000, &sender);
            let events = events_until_final(&mut frames).await;
            assert_eq!(events, [PreviewProxyEvent::Failure { id: 1, reason: PreviewFailure::NotAllowed }]);
        })
        .await;
}

#[tokio::test]
async fn fast_servers_wait_for_the_phone_instead_of_overflowing_the_queue() {
    const TRANSFERS: u32 = 3;
    LocalSet::new()
        .run_until(async {
            let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.expect("binds");
            let port = listener.local_addr().expect("an address").port();
            spawn_local(async move {
                for _ in 0..TRANSFERS {
                    let (mut socket, _) = listener.accept().await.expect("accepts");
                    spawn_local(async move {
                        let body = vec![b'x'; peering_wire::preview::MAX_RESPONSE_BYTES];
                        let mut request = [0u8; 1024];
                        let _read = socket.read(&mut request).await;
                        let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len());
                        let _written = socket.write_all(head.as_bytes()).await;
                        let _written = socket.write_all(&body).await;
                    });
                }
            });
            let (sender, mut frames) = outbound();
            let transfers = PreviewTransfers::default();
            for id in 0..TRANSFERS {
                transfers.handle(get(id, port), 51515, &sender);
            }
            for _ in 0..20_000 {
                tokio::task::yield_now().await;
            }
            assert!(!sender.is_closed(), "the queue overflowed while the phone was not reading");
            let mut ended = 0;
            while ended < TRANSFERS {
                let frame = frames.recv().await.expect("a frame");
                let event: PreviewProxyEvent = serde_json::from_slice(&frame.payload).expect("an event");
                assert!(!matches!(event, PreviewProxyEvent::Failure { .. }), "{event:?}");
                ended += u32::from(matches!(event, PreviewProxyEvent::End { truncated: false, .. }));
            }
        })
        .await;
}
