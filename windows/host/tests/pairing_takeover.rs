mod support;

use peering_wire::framing::MessageKind;
use support::*;

/// Runs a phone from `address` through the handshake and the code exchange, so the host has seen its pairing code.
async fn reveal_from(harness: &Harness, address: &str) -> (Phone, PairingClient) {
    let mut phone = Phone::connect(&harness.runtime, direct_peer_at(address));
    let mut client = PairingClient::new();
    phone.send(role_frame(CONTROL_ROLE)).await;
    phone.send(hello()).await;
    phone.next_of(MessageKind::ServerHello).await;
    client.take_host_commit(&phone.next_of(MessageKind::PairCommit).await);
    phone.send(client.commit()).await;
    let reveal = phone.next_of(MessageKind::PairReveal).await;
    assert!(client.take_host_reveal(&reveal), "the host reveal matches its commitment");
    phone.send(client.reveal()).await;
    for _ in 0..500 {
        tokio::task::yield_now().await;
    }
    (phone, client)
}

fn shown_code(harness: &Harness) -> String {
    harness.runtime.pairing_offer().expect("an offer is shown").code
}

#[test]
fn a_phone_from_another_address_cannot_replace_the_code_on_screen() {
    run(async {
        let harness = harness();
        let (_first, first_client) = reveal_from(&harness, "192.168.1.10").await;
        assert_eq!(shown_code(&harness), first_client.code());

        let (_second, second_client) = reveal_from(&harness, "192.168.1.99").await;

        assert_ne!(first_client.code(), second_client.code());
        assert_eq!(shown_code(&harness), first_client.code());
    });
}

#[test]
fn a_phone_from_another_address_takes_over_after_the_offer_has_gone_stale() {
    run(async {
        let harness = harness();
        let (_first, _first_client) = reveal_from(&harness, "192.168.1.10").await;
        harness.clock.advance(121.0);

        let (_second, second_client) = reveal_from(&harness, "192.168.1.99").await;

        assert_eq!(shown_code(&harness), second_client.code());
    });
}

#[test]
fn a_phone_that_reconnects_from_the_same_address_replaces_its_own_code() {
    run(async {
        let harness = harness();
        let (_first, _first_client) = reveal_from(&harness, "192.168.1.10").await;

        let (_again, again_client) = reveal_from(&harness, "192.168.1.10").await;

        assert_eq!(shown_code(&harness), again_client.code());
    });
}
