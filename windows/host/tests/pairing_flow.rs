mod support;

use peering_core::ports::secret_store::SecretStore;
use peering_host::runtime::PeerInfo;
use peering_wire::framing::MessageKind;
use support::*;

#[test]
fn a_phone_that_pairs_with_the_code_is_authorised_and_remembered() {
    run(async {
        let harness = harness();
        let _phone = paired_phone(&harness.runtime).await;
        let saved = harness
            .secrets
            .read("pairedDevices")
            .expect("the store reads")
            .expect("the pairing is saved");
        assert!(String::from_utf8_lossy(&saved).contains(CLIENT_ID));
    });
}

#[test]
fn a_remembered_phone_is_authorised_without_pairing_again() {
    run(async {
        let harness = harness();
        let _first = paired_phone(&harness.runtime).await;
        let mut second = Phone::connect(&harness.runtime, direct_peer());
        second.send(role_frame(CONTROL_ROLE)).await;
        second.send(hello()).await;
        let hello = server_hello(&second.next_of(MessageKind::ServerHello).await);
        assert!(hello.already_paired);
        assert_eq!(hello.host_platform.as_deref(), Some("windows"));
        assert_eq!(hello.capabilities.supports_file_browser, Some(true));
        assert_eq!(hello.capabilities.supports_agent_chat, Some(true));
        assert_eq!(hello.agent_chat_agents.as_deref(), Some(&["claude".to_owned()][..]));
        second.next_of(MessageKind::Catalog).await;
    });
}

#[test]
fn a_wrong_proof_is_refused_and_nothing_is_saved() {
    run(async {
        let harness = harness();
        let (mut phone, result, _offer) =
            pair_with_peer(&harness.runtime, direct_peer(), |_, _| vec![0u8; 32]).await;
        assert!(!result.accepted);
        assert!(phone.try_next().await.is_none(), "the host closes a refused pairing");
        assert_eq!(harness.secrets.read("pairedDevices"), Ok(None));
    });
}

#[test]
fn a_relayed_pairing_is_marked_as_relayed_on_the_offer() {
    run(async {
        let harness = harness();
        let peer = PeerInfo { via_relay: true, video_token: Some([7; 16]), ..direct_peer() };
        let (_phone, result, offer) = pair_with_peer(&harness.runtime, peer, |client, secret| client.proof(secret)).await;
        assert!(offer.via_relay);
        assert!(result.accepted);
    });
}
