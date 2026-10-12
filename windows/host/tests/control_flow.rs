mod support;

use peering_host::runtime::RuntimeCommand;
use peering_wire::handshake::PairResult;
use peering_wire::framing::MessageKind;
use peering_wire::handshake::PairConfirm;
use support::*;

#[test]
fn a_phone_without_the_qr_secret_completes_pairing_once_the_mac_approves() {
    run(async {
        let harness = harness();
        let mut phone = Phone::connect(&harness.runtime, direct_peer());
        let mut client = PairingClient::new();
        phone.send(role_frame(CONTROL_ROLE)).await;
        phone.send(hello()).await;
        phone.next_of(MessageKind::ServerHello).await;
        client.take_host_commit(&phone.next_of(MessageKind::PairCommit).await);
        phone.send(client.commit()).await;
        let reveal = phone.next_of(MessageKind::PairReveal).await;
        assert!(client.take_host_reveal(&reveal));
        phone.send(client.reveal()).await;
        wait_for_offer(&harness.runtime).await;
        phone.send_json(MessageKind::PairConfirm, &PairConfirm { accepted: true, proof: None }).await;

        let approval = until(|| harness.runtime.snapshot().approvals.first().cloned()).await;
        assert_eq!(approval.client_name, CLIENT_NAME);
        assert!(harness.runtime.approve(approval.id));

        let result: PairResult = decode_json(&phone.next_of(MessageKind::PairResult).await);
        assert!(result.accepted);
        assert!(harness.runtime.snapshot().approvals.is_empty());
    });
}

#[test]
fn switching_hosting_off_from_the_window_ends_the_connected_phones() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        harness.runtime.start_pump();
        assert!(harness.runtime.handle().send(RuntimeCommand::SetHosting(false)));
        while phone.try_next().await.is_some() {}
    });
}
