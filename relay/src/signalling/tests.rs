use super::connection::handle;
use super::notify::{is_agent_category, MAX_DEVICE_TOKEN_HEX};
use super::referral::MAX_REFERRAL_REQUESTS_PER_CONNECTION;
use super::*;
use crate::activity::ActivityRefusal;
use crate::client_ip::{forwarded_address, ClientIpHeader};
use crate::config::PlanAllowances;
use crate::device_proof;
use crate::quota::Plan;
use crate::referrals::{ReferralTerms, Referrals};
use futures_util::SinkExt;
use tokio::time;
use tokio_tungstenite::tungstenite::Message;

#[test]
fn a_device_token_limit_leaves_room_for_an_fcm_token() {
    let fcm_hex_len = ("fcm:".len() + 170) * 2;
    assert!(fcm_hex_len <= MAX_DEVICE_TOKEN_HEX);
    const { assert!(64 <= MAX_DEVICE_TOKEN_HEX, "an APNs token still fits") };
}

#[test]
fn a_mac_may_name_only_the_categories_the_phone_registers() {
    assert!(is_agent_category("peering.agent.approval.tool"));
    assert!(is_agent_category("peering.agent.approval.options.abc"));
    assert!(is_agent_category("peering.agent.finished"));
    assert!(!is_agent_category("peering.agent.finished.extra"));
    assert!(!is_agent_category("com.apple.something"));
}

fn channel() -> (mpsc::Sender<ServerMessage>, mpsc::Receiver<ServerMessage>) {
    mpsc::channel(4)
}

use p256::ecdsa::{Signature, SigningKey, signature::Signer};

fn device_key(seed: u8) -> (SigningKey, String) {
    let signing = SigningKey::from_bytes(&[seed; 32].into()).expect("a valid scalar");
    let public = crate::protocol::bytes_hex(&signing.verifying_key().to_sec1_bytes());
    (signing, public)
}

fn signed(signing: &SigningKey, action: &str, client_id: &str, stamp: u64) -> String {
    let body = device_proof::referral_payload(action, client_id, stamp);
    let signature: Signature = signing.sign(body.as_bytes());
    crate::protocol::bytes_hex(signature.to_der().as_bytes())
}

async fn ask(settings: &Settings, message: ClientMessage) -> Option<ServerMessage> {
    let (tx, _rx) = channel();
    let registry = Arc::new(Registry::new(usize::MAX));
    let mut state = ConnectionState::default();
    dispatch(message, &tx, &registry, &HostRegistry::new(), settings, "127.0.0.1", &mut state).await
}

fn status_request(seed: u8, client_id: &str) -> ClientMessage {
    let (signing, public) = device_key(seed);
    let stamp = unix_now();
    ClientMessage::ReferralStatus {
        client_id: client_id.into(),
        public_key: Some(public),
        proof: Some(signed(&signing, "status", client_id, stamp)),
        proof_time: Some(stamp),
    }
}

fn redeem_request(seed: u8, client_id: &str, code: &str) -> ClientMessage {
    let (signing, public) = device_key(seed);
    let stamp = unix_now();
    ClientMessage::RedeemReferral {
        client_id: client_id.into(),
        code: code.into(),
        public_key: Some(public),
        proof: Some(signed(&signing, &format!("redeem:{code}"), client_id, stamp)),
        proof_time: Some(stamp),
    }
}

fn quota_settings() -> Settings {
    settings_with(Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default())))
}

#[tokio::test]
async fn a_proved_device_is_given_a_code_and_a_friend_can_redeem_it() {
    let settings = quota_settings();
    let Some(ServerMessage::Referral { code, bonus_seconds: 0, .. }) =
        ask(&settings, status_request(1, "owner-phone")).await
    else {
        panic!("expected a code with no bonus yet");
    };

    let reply = ask(&settings, redeem_request(2, "friend-phone", &code)).await;
    assert!(matches!(
        reply,
        Some(ServerMessage::Referral { bonus_seconds: 1800, redeemed: true, .. })
    ), "got {reply:?}");

    // The bonus is on the key the friend proves, and is what the quota check reads.
    let (_, friend_key) = device_key(2);
    assert_eq!(settings.quota.remaining(&friend_key, None, Plan::Free), Some(1800 + 1800));
    let (_, owner_key) = device_key(1);
    assert_eq!(settings.quota.remaining(&owner_key, None, Plan::Free), Some(1800 + 1800));
}

#[tokio::test]
async fn an_invite_request_without_a_proof_is_refused() {
    let settings = quota_settings();
    let reply = ask(
        &settings,
        ClientMessage::ReferralStatus {
            client_id: "phone".into(),
            public_key: None,
            proof: None,
            proof_time: None,
        },
    )
    .await;
    assert!(matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "proofRequired"));
}

#[tokio::test]
async fn a_redemption_signed_for_another_code_is_refused() {
    let settings = quota_settings();
    let Some(ServerMessage::Referral { code, .. }) =
        ask(&settings, status_request(1, "owner-phone")).await
    else {
        panic!("expected a code");
    };
    let ClientMessage::RedeemReferral { client_id, public_key, proof, proof_time, .. } =
        redeem_request(2, "friend-phone", "AAAAAAAA")
    else {
        unreachable!()
    };
    let reply = ask(
        &settings,
        ClientMessage::RedeemReferral { client_id, code, public_key, proof, proof_time },
    )
    .await;
    assert!(matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "proofInvalid"));
}

#[tokio::test]
async fn redeeming_twice_or_your_own_code_is_refused() {
    let settings = quota_settings();
    let Some(ServerMessage::Referral { code, .. }) =
        ask(&settings, status_request(1, "owner-phone")).await
    else {
        panic!("expected a code");
    };
    let own = ask(&settings, redeem_request(1, "owner-phone", &code)).await;
    assert!(matches!(own, Some(ServerMessage::Error { ref code, .. }) if code == "referralOwnCode"));

    ask(&settings, redeem_request(2, "friend-phone", &code)).await;
    let again = ask(&settings, redeem_request(2, "friend-phone", &code)).await;
    assert!(matches!(again, Some(ServerMessage::Error { ref code, .. }) if code == "referralAlreadyRedeemed"));
}

#[tokio::test]
async fn a_connection_that_keeps_asking_is_told_to_reconnect() {
    let settings = quota_settings();
    let (tx, _rx) = channel();
    let registry = Arc::new(Registry::new(usize::MAX));
    let hosts = HostRegistry::new();
    let mut state = ConnectionState::default();
    let mut last = None;
    for _ in 0..=MAX_REFERRAL_REQUESTS_PER_CONNECTION {
        last = dispatch(status_request(1, "p"), &tx, &registry, &hosts, &settings, "127.0.0.1", &mut state).await;
    }
    assert!(matches!(last, Some(ServerMessage::Error { ref code, .. }) if code == "tooManyRequests"));
}

/// The port every session is told to send video to. A fixed number rather than a bound socket:
/// what these tests are about is what signalling *says*, and the port it says it on is decided
/// at startup and belongs to `udp_relay`'s own tests and to the end-to-end ones.
const VIDEO_PORT: u16 = 30190;

fn settings_with(quota: Arc<QuotaTracker>) -> Settings {
    Settings {
        host: None,
        public_control_port: 9443,
        video_port: VIDEO_PORT,
        session_ttl: Duration::from_secs(60),
        quota,
        // Pinned to Apple's real root, so a receipt in these tests verifies only if someone
        // has Apple's signing key. The receipt path itself is exercised in `storekit`'s own
        // tests, where the chain is one the test can actually sign with.
        receipts: Arc::new(StoreKitVerifier::apple(true)),
        // Open by default, because almost every test here is about something else and a
        // ceiling that refuses sessions would show up as a mystery failure in all of them.
        // The ceilings have their own tests, below.
        max_sessions: usize::MAX,
        max_connections: usize::MAX,
        handshake_timeout: Duration::from_secs(10),
        idle_timeout: Duration::from_secs(90),
        apns: None,
        fcm: None,
        play: None,
        limiter: Arc::new(crate::limits::PeerLimiter::default()),
        require_proven_hosts: false,
        activity_budget: Default::default(),
    }
}

/// The allowances the app states, which are the relay's defaults: 30 minutes free and no limit
/// on paid plans.
fn default_settings() -> Settings {
    settings_with(Arc::new(QuotaTracker::new(
        PlanAllowances::default(),
        Default::default(),
    )))
}

fn activity_message(token: &str) -> ClientMessage {
    serde_json::from_str(&format!(
        r#"{{"type":"notifyActivity","activityToken":"{token}","activity":"session","event":"update","contentState":{{"n":1}}}}"#
    ))
    .expect("parses")
}

async fn ask_as_host(state: &mut ConnectionState, message: ClientMessage) -> Option<ServerMessage> {
    let (tx, _rx) = channel();
    let registry = Arc::new(Registry::new(usize::MAX));
    dispatch(message, &tx, &registry, &HostRegistry::new(), &default_settings(), "127.0.0.1", state).await
}

#[tokio::test]
async fn an_unregistered_connection_may_not_push_an_activity() {
    let reply = ask(&default_settings(), activity_message(&"ab".repeat(32))).await;
    assert!(matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "unauthorized"));
}

#[tokio::test]
async fn a_registered_host_without_apns_is_told_the_push_is_unavailable() {
    let mut state = ConnectionState { registered_as: Some("mac".into()), ..Default::default() };
    let reply = ask_as_host(&mut state, activity_message(&"ab".repeat(32))).await;
    assert_eq!(reply, Some(ServerMessage::ActivityRefused { reason: ActivityRefusal::Unavailable, request_id: None }));
}

#[tokio::test]
async fn a_bad_activity_token_or_an_fcm_token_is_refused_as_an_invalid_token() {
    let mut state = ConnectionState { registered_as: Some("mac".into()), ..Default::default() };
    let fcm = crate::protocol::bytes_hex(b"fcm:abc123");
    for token in ["zz", fcm.as_str()] {
        let reply = ask_as_host(&mut state, activity_message(token)).await;
        assert_eq!(reply, Some(ServerMessage::ActivityRefused { reason: ActivityRefusal::InvalidToken, request_id: None }));
    }
}

#[tokio::test]
async fn pushes_past_the_burst_are_dropped_without_a_reply() {
    let mut state = ConnectionState { registered_as: Some("mac".into()), ..Default::default() };
    let token = "ab".repeat(32);
    for _ in 0..5 {
        assert!(ask_as_host(&mut state, activity_message(&token)).await.is_some());
    }
    assert_eq!(ask_as_host(&mut state, activity_message(&token)).await, None);
}

#[tokio::test]
async fn a_token_cannot_be_hammered_through_many_connections() {
    let settings = default_settings();
    let token = "ab".repeat(32);
    let (tx, _rx) = channel();
    let registry = Arc::new(Registry::new(usize::MAX));
    let mut answered = 0;
    for _ in 0..20 {
        let mut state = ConnectionState { registered_as: Some("mac".into()), ..Default::default() };
        let reply = dispatch(activity_message(&token), &tx, &registry, &HostRegistry::new(), &settings, "127.0.0.1", &mut state).await;
        answered += usize::from(reply.is_some());
    }
    assert_eq!(answered, 5, "a new connection each time does not reset the token's budget");
}

#[test]
fn a_refusal_serialises_with_a_reason_from_the_closed_set_and_nothing_else() {
    let json = serde_json::to_string(&ServerMessage::ActivityRefused { reason: ActivityRefusal::InvalidToken, request_id: None }).unwrap();
    assert_eq!(json, r#"{"type":"activityRefused","reason":"invalidToken"}"#);
}

#[test]
fn a_refusal_echoes_the_request_id_verbatim() {
    let refused = ServerMessage::ActivityRefused { reason: ActivityRefusal::Rejected, request_id: Some("r-7".into()) };
    assert_eq!(serde_json::to_string(&refused).unwrap(), r#"{"type":"activityRefused","reason":"rejected","requestId":"r-7"}"#);
}

#[tokio::test]
async fn a_synchronous_refusal_carries_the_pushs_request_id() {
    let mut state = ConnectionState { registered_as: Some("mac".into()), ..Default::default() };
    let ClientMessage::NotifyActivity(mut push) = activity_message("zz") else { panic!("not a notifyActivity") };
    push.request_id = Some("r-9".into());
    let reply = ask_as_host(&mut state, ClientMessage::NotifyActivity(push)).await;
    assert_eq!(reply, Some(ServerMessage::ActivityRefused { reason: ActivityRefusal::InvalidToken, request_id: Some("r-9".into()) }));
}

#[tokio::test]
async fn a_registered_host_can_be_looked_up() {
    let hosts = HostRegistry::new();
    let (tx, _rx) = channel();
    hosts
        .put("mac", 3, tx, None)
        .await
        .expect("an unproved registration is accepted while nothing is bound");

    let host = hosts.entry_for("mac").await.expect("should be found");
    assert_eq!(host.protocol_version, 3);
    assert!(hosts.entry_for("other").await.is_none());
    assert_eq!(hosts.online_count().await, 1);
}

#[tokio::test]
async fn a_replaced_host_is_not_evicted_by_its_predecessors_cleanup() {
    // The laptop-changes-networks case. The old signalling socket closes *after* the new one
    // registered, so cleanup for the old must not take the new registration with it.
    let hosts = HostRegistry::new();
    let (old_tx, _old_rx) = channel();
    let (new_tx, _new_rx) = channel();

    hosts
        .put("mac", 3, old_tx.clone(), None)
        .await
        .expect("an unproved registration is accepted while nothing is bound");
    hosts
        .put("mac", 3, new_tx.clone(), None)
        .await
        .expect("an unproved registration is accepted while nothing is bound");

    hosts.remove_if_ours("mac", &old_tx).await;
    assert_eq!(
        hosts.online_count().await,
        1,
        "the stale connection must not unregister the live one"
    );

    hosts.remove_if_ours("mac", &new_tx).await;
    assert_eq!(hosts.online_count().await, 0, "the real owner still can");
}

#[tokio::test]
async fn presence_is_answered_from_the_registry() {
    let registry = Arc::new(Registry::new(usize::MAX));
    let hosts = HostRegistry::new();
    let (host_tx, _host_rx) = channel();
    hosts
        .put("mac", 3, host_tx, None)
        .await
        .expect("an unproved registration is accepted while nothing is bound");

    let settings = default_settings();

    let answer = |host_id: &str, hosts: &HostRegistry, registry: &Arc<Registry>| {
        let hosts = hosts.clone();
        let registry = Arc::clone(registry);
        let settings = settings.clone();
        let (tx, _rx) = channel();
        let host_id = host_id.to_string();
        async move {
            dispatch(
                ClientMessage::HostPresence { host_id: host_id.clone() },
                &tx,
                &registry,
                &hosts,
                &settings,
                "127.0.0.1",
                &mut ConnectionState::default(),
            )
            .await
        }
    };

    assert_eq!(
        answer("mac", &hosts, &registry).await,
        Some(ServerMessage::HostPresence { host_id: "mac".into(), online: true })
    );
    assert_eq!(
        answer("ghost", &hosts, &registry).await,
        Some(ServerMessage::HostPresence { host_id: "ghost".into(), online: false }),
        "an unregistered Mac is answered, not refused: the phone asked a question and no is an answer"
    );

    // And asking opens nothing. The whole point of a presence query over the app's old
    // approach of simply trying to connect is that it does not cost a session.
    assert_eq!(registry.len().await, 0, "presence must not allocate a session");
}

/// The answer follows the registration, so a Mac that has gone is reported gone.
#[tokio::test]
async fn a_mac_that_has_gone_is_reported_offline() {
    let registry = Arc::new(Registry::new(usize::MAX));
    let hosts = HostRegistry::new();
    let (host_tx, _host_rx) = channel();
    hosts
        .put("mac", 3, host_tx.clone(), None)
        .await
        .expect("an unproved registration is accepted while nothing is bound");

    let settings = default_settings();
    let ask = |hosts: &HostRegistry, registry: &Arc<Registry>, settings: &Settings| {
        let hosts = hosts.clone();
        let registry = Arc::clone(registry);
        let settings = settings.clone();
        async move {
            let (tx, _rx) = channel();
            dispatch(
                ClientMessage::HostPresence { host_id: "mac".into() },
                &tx,
                &registry,
                &hosts,
                &settings,
                "127.0.0.1",
                &mut ConnectionState::default(),
            )
            .await
        }
    };

    assert!(matches!(
        ask(&hosts, &registry, &settings).await,
        Some(ServerMessage::HostPresence { online: true, .. })
    ));

    // The Mac's socket dropping is what a laptop changing networks looks like from here.
    hosts.remove_if_ours("mac", &host_tx).await;

    assert_eq!(
        ask(&hosts, &registry, &settings).await,
        Some(ServerMessage::HostPresence { host_id: "mac".into(), online: false })
    );
}

#[tokio::test]
async fn asking_for_an_unknown_host_reports_it_offline() {
    let registry = Arc::new(Registry::new(usize::MAX));
    let hosts = HostRegistry::new();
    let settings = default_settings();
    let (tx, _rx) = channel();
    let mut state = ConnectionState::default();

    let reply = dispatch(
        ClientMessage::ConnectToHost {
            host_id: "ghost".into(),
            client_id: "phone".into(),
            protocol_version: 3,
            api_key: None,
            plan: None,
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
            play_purchase_token: None,
            play_product_id: None,
        },
        &tx,
        &registry,
        &hosts,
        &settings,
        "127.0.0.1",
        &mut state,
    )
    .await;

    assert_eq!(
        reply,
        Some(ServerMessage::HostOffline {
            device_id: "ghost".into()
        })
    );
    assert_eq!(registry.len().await, 0, "no session should be left behind");
}

#[tokio::test]
async fn a_version_mismatch_is_refused_before_any_session_exists() {
    let registry = Arc::new(Registry::new(usize::MAX));
    let hosts = HostRegistry::new();
    let (host_tx, _host_rx) = channel();
    hosts
        .put("mac", 3, host_tx, None)
        .await
        .expect("an unproved registration is accepted while nothing is bound");

    let settings = default_settings();
    let (tx, _rx) = channel();
    let mut state = ConnectionState::default();

    let reply = dispatch(
        ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 2,
            api_key: None,
            plan: None,
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
            play_purchase_token: None,
            play_product_id: None,
        },
        &tx,
        &registry,
        &hosts,
        &settings,
        "127.0.0.1",
        &mut state,
    )
    .await;

    assert!(matches!(reply, Some(ServerMessage::Error { .. })));
    assert_eq!(registry.len().await, 0);
}

#[tokio::test]
async fn connecting_reaches_the_mac_as_well_as_the_phone() {
    let registry = Arc::new(Registry::new(usize::MAX));
    let hosts = HostRegistry::new();
    let (host_tx, mut host_rx) = channel();
    hosts
        .put("mac", 3, host_tx, None)
        .await
        .expect("an unproved registration is accepted while nothing is bound");

    let settings = default_settings();
    let (tx, _rx) = channel();
    let mut state = ConnectionState::default();

    let reply = dispatch(
        ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
            api_key: None,
            plan: None,
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
            play_purchase_token: None,
            play_product_id: None,
        },
        &tx,
        &registry,
        &hosts,
        &settings,
        "relay.test",
        &mut state,
    )
    .await;

    // The phone is told where to go...
    let ready = match reply.expect("the phone should get a session") {
        ServerMessage::SessionReady {
            control_host,
            control_port,
            video_host,
            video_port,
            control_token,
            video_token,
            remaining_seconds: _,
        } => (control_host, control_port, video_host, video_port, control_token, video_token),
        other => panic!("expected a session, got {other:?}"),
    };
    assert_eq!(ready.0, "relay.test");
    assert_eq!(ready.1, 9443);
    assert_eq!(
        ready.3, VIDEO_PORT,
        "the session is told the one port the shared socket is on"
    );

    // ...and so is the Mac, which never asked. Everything matches except the video token,
    // the two ends have to be distinguishable, so that a re-bind from one cannot move the
    // other's address.
    let Some(ServerMessage::SessionReady {
        control_host,
        control_port,
        video_host,
        video_port,
        control_token,
        video_token,
        remaining_seconds: _,
    }) = host_rx.recv().await
    else {
        panic!("the Mac should be pushed a session too");
    };

    assert_eq!((control_host, control_port), (ready.0, ready.1));
    assert_eq!((video_host, video_port), (ready.2, ready.3));
    assert_eq!(control_token, ready.4);
    assert_ne!(video_token, ready.5, "the two ends must not share a token");
}

/// Sends one connect request against a Mac that is registered and a counter that is already
/// spent, and reports what the phone was told.
async fn connect_with(plan: Option<&str>, spent_seconds: u64) -> Option<ServerMessage> {
    let quota = Arc::new(QuotaTracker::new(PlanAllowances::default(), Default::default()));
    // Recorded rather than configured away, so the test travels the same path a client does.
    quota.record("phone", Duration::from_secs(spent_seconds));
    connect_against(quota, plan).await
}

async fn connect_against(quota: Arc<QuotaTracker>, plan: Option<&str>) -> Option<ServerMessage> {
    let registry = Arc::new(Registry::new(usize::MAX));
    let hosts = HostRegistry::new();
    let (host_tx, _host_rx) = channel();
    hosts
        .put("mac", 3, host_tx, None)
        .await
        .expect("an unproved registration is accepted while nothing is bound");

    let settings = settings_with(quota);

    let (tx, _rx) = channel();
    let mut state = ConnectionState::default();
    dispatch(
        ClientMessage::ConnectToHost {
            host_id: "mac".into(),
            client_id: "phone".into(),
            protocol_version: 3,
            api_key: None,
            plan: plan.map(str::to_string),
            jws_representation: None,
            public_key: None,
            proof: None,
            proof_time: None,
            play_purchase_token: None,
            play_product_id: None,
        },
        &tx,
        &registry,
        &hosts,
        &settings,
        "127.0.0.1",
        &mut state,
    )
    .await
}

fn remaining_in(reply: Option<ServerMessage>) -> Option<u64> {
    match reply {
        Some(ServerMessage::SessionReady { remaining_seconds, .. }) => remaining_seconds,
        other => panic!("expected a session, got {other:?}"),
    }
}

#[tokio::test]
async fn a_free_session_reports_what_is_left_of_the_allowance() {
    let reply = connect_with(None, 100).await;
    assert_eq!(remaining_in(reply), Some(30 * 60 - 100));
}

#[tokio::test]
async fn a_paid_plan_session_omits_the_remaining_seconds() {
    for plan in ["relay", "plus", "pro"] {
        let reply = connect_with(Some(plan), 100).await;
        assert_eq!(remaining_in(reply), None, "{plan}");
    }
}

#[tokio::test]
async fn an_unlimited_allowance_omits_the_remaining_seconds() {
    let allowances = PlanAllowances { free_seconds: None, ..PlanAllowances::default() };
    let quota = Arc::new(QuotaTracker::new(allowances, Default::default()));
    assert_eq!(remaining_in(connect_against(quota, None).await), None);
}

#[tokio::test]
async fn a_referral_bonus_is_included_in_the_remaining_seconds() {
    let referrals = Arc::new(Referrals::in_memory(ReferralTerms::default()));
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let code = referrals.standing("owner", now).unwrap().code;
    referrals.redeem("phone", &code, now).unwrap();
    let quota = Arc::new(
        QuotaTracker::new(PlanAllowances::default(), Default::default()).with_referrals(referrals),
    );
    quota.record("phone", Duration::from_secs(1000));
    let bonus = ReferralTerms::default().bonus_seconds;
    assert_eq!(remaining_in(connect_against(quota, None).await), Some(30 * 60 + bonus - 1000));
}

/// 30 minutes free means 30 minutes: a client that has spent more than that is refused.
#[tokio::test]
async fn a_spent_free_allowance_is_refused() {
    let reply = connect_with(None, 30 * 60 + 1).await;
    assert!(
        matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "quotaExceeded"),
        "expected a quota refusal, got {reply:?}"
    );
}

/// The same client, saying `relay`, is not metered at all, which is the whole of what a
/// subscription buys here.
#[tokio::test]
async fn a_relay_plan_is_not_metered() {
    let reply = connect_with(Some("relay"), 100 * 3600).await;
    assert!(
        matches!(reply, Some(ServerMessage::SessionReady { .. })),
        "Relay should be unlimited: {reply:?}"
    );
}

/// And a client saying `pro` is not blocked by the counter at all.
#[tokio::test]
async fn a_pro_plan_is_not_blocked_by_its_counter() {
    for plan in ["plus", "pro"] {
        let reply = connect_with(Some(plan), 100 * 3600).await;
        assert!(
            matches!(reply, Some(ServerMessage::SessionReady { .. })),
            "{plan} should not be metered, got {reply:?}"
        );
    }
}

/// The trust boundary, stated as a test: the plan is the client's word, so the only defence
/// is that an unrecognised word buys nothing. `pro` spelled any other way is free.
#[tokio::test]
async fn a_plan_the_relay_does_not_know_is_metered_as_free() {
    for claimed in ["enterprise", "unlimited", "pro max", ""] {
        let reply = connect_with(Some(claimed), 30 * 60 + 1).await;
        assert!(
            matches!(reply, Some(ServerMessage::Error { ref code, .. }) if code == "quotaExceeded"),
            "{claimed:?} should have been metered as free, got {reply:?}"
        );
    }
}

fn register(device_id: &str, proved: bool) -> ClientMessage {
    let (signing, public) = device_key(9);
    let stamp = unix_now();
    let body = device_proof::payload(device_id, stamp);
    let signature: Signature = signing.sign(body.as_bytes());
    ClientMessage::RegisterHost {
        device_id: device_id.into(),
        name: "Studio".into(),
        protocol_version: 3,
        public_key: proved.then_some(public),
        proof: proved.then(|| crate::protocol::bytes_hex(signature.to_der().as_bytes())),
        proof_time: proved.then_some(stamp),
    }
}

fn connect_to(host_id: &str) -> ClientMessage {
    serde_json::from_str(&format!(
        r#"{{"type":"connectToHost","hostId":"{host_id}","clientId":"phone","protocolVersion":3,"plan":"free"}}"#
    ))
    .expect("parses")
}

#[tokio::test]
async fn a_second_registration_on_one_connection_replaces_the_first() {
    let hosts = HostRegistry::new();
    let registry = Arc::new(Registry::new(usize::MAX));
    let settings = default_settings();
    let (tx, _rx) = channel();
    let mut state = ConnectionState::default();

    for id in ["one", "two"] {
        let reply = dispatch(register(id, false), &tx, &registry, &hosts, &settings, "127.0.0.1", &mut state).await;
        assert!(matches!(reply, Some(ServerMessage::Registered { .. })));
    }

    assert!(hosts.entry_for("one").await.is_none(), "the earlier id must not linger");
    assert!(hosts.entry_for("two").await.is_some());
    assert_eq!(hosts.online_count().await, 1);
}

#[tokio::test]
async fn a_host_whose_connection_is_gone_is_not_present_even_if_cleanup_never_ran() {
    let hosts = HostRegistry::new();
    let (tx, rx) = channel();
    hosts.put("mac", 3, tx, None).await.unwrap();
    assert!(hosts.entry_for("mac").await.is_some());

    drop(rx);
    assert_eq!(hosts.online_count().await, 0);
    assert!(hosts.entry_for("mac").await.is_none());
}

#[tokio::test]
async fn only_a_proven_host_can_be_connected_to_when_proof_is_required() {
    let hosts = HostRegistry::new();
    let registry = Arc::new(Registry::new(usize::MAX));
    let mut settings = default_settings();
    settings.require_proven_hosts = true;
    let (host_tx, _host_rx) = channel();
    let mut host_state = ConnectionState::default();
    for (id, proved) in [("old", false), ("new", true)] {
        dispatch(register(id, proved), &host_tx, &registry, &hosts, &settings, "127.0.0.1", &mut host_state).await;
    }
    // Registered under one connection, the second replaced the first, so register "old" again
    // on its own connection.
    let (old_tx, _old_rx) = channel();
    dispatch(register("old", false), &old_tx, &registry, &hosts, &settings, "127.0.0.1", &mut ConnectionState::default()).await;

    let (tx, _rx) = channel();
    let mut state = ConnectionState::default();
    let unproven = dispatch(connect_to("old"), &tx, &registry, &hosts, &settings, "127.0.0.1", &mut state).await;
    assert_eq!(unproven, Some(ServerMessage::HostOffline { device_id: "old".into() }));
    let proven = dispatch(connect_to("new"), &tx, &registry, &hosts, &settings, "127.0.0.1", &mut state).await;
    assert!(matches!(proven, Some(ServerMessage::SessionReady { .. })), "got {proven:?}");
}

#[tokio::test]
async fn an_address_over_its_allocation_rate_or_unspliced_cap_is_refused_before_allocating() {
    let hosts = HostRegistry::new();
    let registry = Arc::new(Registry::new(usize::MAX));
    let mut settings = default_settings();
    settings.limiter = Arc::new(PeerLimiter::new(crate::limits::IpLimits {
        exempt_loopback: false,
        unspliced_sessions: 1,
        ..Default::default()
    }));
    let (host_tx, _host_rx) = mpsc::channel(8);
    hosts.put("mac", 3, host_tx, None).await.unwrap();

    let (tx, _rx) = channel();
    let mut state = ConnectionState { peer: Some("203.0.113.4".parse().unwrap()), ..Default::default() };
    let first = dispatch(connect_to("mac"), &tx, &registry, &hosts, &settings, "127.0.0.1", &mut state).await;
    assert!(matches!(first, Some(ServerMessage::SessionReady { .. })));

    let mut other = ConnectionState { peer: Some("203.0.113.4".parse().unwrap()), ..Default::default() };
    let refused = dispatch(
        serde_json::from_str(r#"{"type":"connectToHost","hostId":"mac","clientId":"second","protocolVersion":3,"plan":"free"}"#).unwrap(),
        &tx, &registry, &hosts, &settings, "127.0.0.1", &mut other,
    )
    .await;
    assert!(matches!(refused, Some(ServerMessage::Error { ref code, .. }) if code == "tooManySessions"));
    assert_eq!(registry.len().await, 1, "nothing was allocated for the refused one");
}

#[tokio::test]
async fn a_client_that_stops_reading_is_dropped_by_the_write_timeout() {
    let (server_end, client_end) = tokio::io::duplex(256);
    let mut settings = default_settings();
    settings.handshake_timeout = Duration::from_millis(300);
    settings.idle_timeout = Duration::from_secs(60);
    let server = tokio::spawn(handle(
        server_end,
        None,
        "127.0.0.1".into(),
        Arc::new(Registry::new(usize::MAX)),
        HostRegistry::new(),
        settings,
    ));

    let (mut ws, _) = tokio_tungstenite::client_async("ws://localhost/", client_end).await.unwrap();
    let ping = serde_json::to_string(&ClientMessage::Ping).unwrap();
    // Replies pile up in a 256 byte pipe nobody reads. The client is kept alive until the end
    // so a pass cannot be the server noticing a close.
    let flood = tokio::spawn(async move {
        for _ in 0..400 {
            if ws.send(Message::Text(ping.clone().into())).await.is_err() {
                break;
            }
        }
        ws
    });

    let finished = time::timeout(Duration::from_secs(3), server).await;
    assert!(finished.is_ok(), "a peer that never reads must not hold the connection past the write timeout");
    flood.abort();
}

fn real_ip_headers(value: &str) -> http::HeaderMap {
    let mut map = http::HeaderMap::new();
    map.insert("x-real-ip", value.parse().unwrap());
    map
}

#[test]
fn forwarded_v6_clients_are_limited_by_their_prefix() {
    let limiter = Arc::new(PeerLimiter::new(crate::limits::IpLimits {
        signalling_connections: 1,
        ..Default::default()
    }));
    let loopback: IpAddr = "127.0.0.1".parse().unwrap();
    let first = forwarded_address(loopback, &real_ip_headers("2001:db8:5:6::1"), ClientIpHeader::XRealIp).unwrap();
    let sibling = forwarded_address(loopback, &real_ip_headers("2001:db8:5:6:aaaa::2"), ClientIpHeader::XRealIp).unwrap();
    let _held = limiter.admit_signalling(first).unwrap();
    assert!(limiter.admit_signalling(sibling).is_none());
}
