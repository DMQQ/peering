mod support;

use peering_core::ports::secret_store::SecretStore;
use peering_host::runtime::RuntimeCommand;
use support::*;

const LIST: &str = "pairedDevices";
const BACKUP: &str = "pairedDevices-bad";

#[test]
fn an_unreadable_paired_list_is_offered_for_reset_and_pairing_works_after_it() {
    run(async {
        let harness = harness_with_stored_secret(LIST, b"{ not a list");
        assert!(harness.runtime.snapshot().paired_list_unreadable);
        let (_phone, refused, _offer) = pair_with_peer(&harness.runtime, direct_peer(), |client, secret| client.proof(secret)).await;
        assert!(!refused.accepted, "pairing is paused while the list cannot be read");

        harness.runtime.start_pump();
        assert!(harness.runtime.handle().send(RuntimeCommand::ResetPairedDevices));
        until(|| (!harness.runtime.snapshot().paired_list_unreadable).then_some(())).await;

        assert!(harness.runtime.snapshot().problems.is_empty());
        assert_eq!(harness.secrets.read(BACKUP), Ok(Some(b"{ not a list".to_vec())));
        let (_phone, accepted, _offer) = pair_with_peer(&harness.runtime, direct_peer(), |client, secret| client.proof(secret)).await;
        assert!(accepted.accepted, "a fresh list takes the pairing");
    });
}

#[test]
fn a_reset_that_cannot_keep_a_copy_says_so_and_changes_nothing() {
    run(async {
        let harness = harness_with_stored_secret(LIST, b"{ not a list");
        harness.secrets.set_fail_writes(true);
        harness.runtime.start_pump();

        assert!(harness.runtime.handle().send(RuntimeCommand::ResetPairedDevices));
        until(|| harness.runtime.snapshot().problems.iter().any(|problem| problem.contains("was not reset")).then_some(())).await;

        assert!(harness.runtime.snapshot().paired_list_unreadable);
        harness.secrets.set_fail_writes(false);
        assert_eq!(harness.secrets.read(LIST), Ok(Some(b"{ not a list".to_vec())));
    });
}
