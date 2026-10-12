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

#[test]
fn forgetting_a_device_ends_its_live_session_and_releases_its_input() {
    run_paused(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        harness.runtime.start_pump();
        let released_before = harness.input.lock().expect("the input is not poisoned").release_all_count();

        assert!(harness.runtime.handle().send(RuntimeCommand::Forget(CLIENT_ID.to_owned())));
        while phone.try_next().await.is_some() {}

        assert!(harness.input.lock().expect("the input is not poisoned").release_all_count() > released_before);
        assert!(harness.runtime.snapshot().devices.is_empty());
        assert_eq!(harness.runtime.snapshot().connected_clients, 0);
    });
}

#[test]
fn forgetting_another_device_leaves_the_session_alone() {
    run_paused(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        harness.runtime.start_pump();

        assert!(harness.runtime.handle().send(RuntimeCommand::Forget("someone-else".to_owned())));
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;

        phone.sync().await;
    });
}
