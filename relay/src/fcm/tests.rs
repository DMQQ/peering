use super::*;
use crate::apns::PushAction;

fn route<'a>(source: Option<&'a str>, action: Option<PushAction<'a>>) -> PushRoute<'a> {
    PushRoute { host_id: "MAC-1", source, action }
}

fn approval() -> PushAction<'static> {
    PushAction {
        category: "peering.agent.approval.tool",
        session_id: "S-1",
        approval_id: "A-1",
    }
}

fn client_answering(status: u16, body: &str) -> (FcmClient, SentPosts) {
    let (transport, sent) = FakeFcmTransport::answering(status, body);
    let client = FcmClient::new(
        "peering-test".to_owned(),
        FakeAccessTokens::giving("ya29.test"),
        transport,
    );
    (client, sent)
}

#[test]
fn the_notification_is_high_priority_with_the_title_and_body() {
    let message = FcmMessage::build("tok", "Title", "Body", None);
    assert_eq!(message["message"]["token"], "tok");
    assert_eq!(message["message"]["notification"]["title"], "Title");
    assert_eq!(message["message"]["notification"]["body"], "Body");
    assert_eq!(message["message"]["android"]["priority"], "HIGH");
}

#[test]
fn a_push_without_a_route_has_no_data_object() {
    let message = FcmMessage::build("tok", "T", "B", None);
    assert!(message["message"].get("data").is_none());
}

#[test]
fn a_route_puts_the_host_and_source_in_data() {
    let message = FcmMessage::build("tok", "T", "B", Some(route(Some("window:42"), None)));
    assert_eq!(message["message"]["data"]["hostId"], "MAC-1");
    assert_eq!(message["message"]["data"]["source"], "window:42");
    assert!(message["message"]["data"].get("category").is_none());
    assert!(message["message"]["data"].get("agentApprovalId").is_none());
}

#[test]
fn a_route_without_a_source_omits_the_source_key() {
    let message = FcmMessage::build("tok", "T", "B", Some(route(None, None)));
    assert_eq!(message["message"]["data"]["hostId"], "MAC-1");
    assert!(message["message"]["data"].get("source").is_none());
}

#[test]
fn an_approval_puts_its_category_and_ids_in_data() {
    let message = FcmMessage::build("tok", "T", "B", Some(route(None, Some(approval()))));
    assert_eq!(message["message"]["data"]["category"], "peering.agent.approval.tool");
    assert_eq!(message["message"]["data"]["agentSessionId"], "S-1");
    assert_eq!(message["message"]["data"]["agentApprovalId"], "A-1");
}

#[tokio::test]
async fn a_send_posts_to_the_project_endpoint_with_the_bearer_token() {
    let (client, sent) = client_answering(200, "{}");
    let outcome = client.send("tok", "T", "B", None).await.expect("sends");
    assert_eq!(outcome, FcmOutcome::Accepted);

    let posts = sent.lock().unwrap();
    assert_eq!(posts.len(), 1);
    assert_eq!(
        posts[0].url,
        "https://fcm.googleapis.com/v1/projects/peering-test/messages:send"
    );
    assert_eq!(posts[0].bearer, "ya29.test");
    let body: Value = serde_json::from_str(&posts[0].body).expect("JSON body");
    assert_eq!(body["message"]["token"], "tok");
}

#[tokio::test]
async fn a_404_is_reported_as_an_unregistered_token() {
    let (client, _) = client_answering(404, r#"{"error":{"status":"NOT_FOUND"}}"#);
    assert_eq!(client.send("tok", "T", "B", None).await.unwrap(), FcmOutcome::Unregistered);
}

#[tokio::test]
async fn an_unregistered_status_in_the_body_is_reported_as_unregistered() {
    let (client, _) = client_answering(400, r#"{"error":{"details":[{"errorCode":"UNREGISTERED"}]}}"#);
    assert_eq!(client.send("tok", "T", "B", None).await.unwrap(), FcmOutcome::Unregistered);
}

#[tokio::test]
async fn any_other_refusal_is_an_error() {
    let (client, _) = client_answering(500, "");
    assert!(client.send("tok", "T", "B", None).await.is_err());
}

#[tokio::test]
async fn a_token_that_cannot_be_minted_sends_nothing() {
    let (transport, sent) = FakeFcmTransport::answering(200, "{}");
    let client = FcmClient::new(
        "peering-test".to_owned(),
        FakeAccessTokens::refusing("invalid_grant"),
        transport,
    );
    assert!(client.send("tok", "T", "B", None).await.is_err());
    assert!(sent.lock().unwrap().is_empty());
}
