use super::*;
use ring::signature::{RSA_PKCS1_2048_8192_SHA256, UnparsedPublicKey};

/// A throwaway 2048 bit key generated for these tests. It signs nothing outside them and is
/// not a secret.
const TEST_ONLY_KEY: &str = "-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDfFfZXtO5r2Eq3
5cwWJXCJXZjHocErwbLErm40mmznyiDCSlEyNpAbQCaYctXkxBrgSttmH29TXDTN
ZsL5iurN9uq7sBsJEPpsFrLY4eCZzqVntC2Br0t+iEZwaZEH3XIN2dxog73qKc7R
5gkrQYLiH+iDbo6kvsSJRRLPjc7BVrtF+6CkMdhslhpmktBBnA6klqtwsxBD3XJ4
O8juFLhTphkB4ByN6SO+MDaQ0PC0LUxQ9BQrunoNeOTy+1/J5B94BCR//ikLi2wV
C0H045Di0jdEAodyb9iiLrs0MOhVEKrk803iNDcjfo110h5xGPLyBGEoN6oMR0ms
0mBUWbDdAgMBAAECggEBAK4Lemeu9xwYYSLcG79jcksZRKrrHcQ/mHMuCzjrCfBE
mA484OAmBYPdJr9lSE70WGuIu2cPO1Fz7JYbiB4cLViHPVc068LFBjrx8pKWlx4o
RI+F2MMGugV72Ei3c7kJIYSA5h58OdzIxVyo9ZpTwAMfFc4EoTESzE60Hxri7d2T
kh9eRGCtMQ9J0ZQGXkWgj8Pm3PzdXCG8rRhp0aqi1soCuXaausGdN9fqLpvOVSxo
3Zo6EupTwOHnXNIdqX0CpdSsiYa1JWbnYuQl53GRV/k+Q3Cer6hsxoDJzq+brtA5
gnFt1LPsvC8j1UiKKLRjEVQZpRPxAhXx9b+N8BzAiNkCgYEA77dKUHY8MAj/At77
Fw/CBehjeCeLZOdiFBejF1u6J6bfTB0bEToLbXJ8XWIduMt3DvWHsHH36meIn3++
KkJzT8pl5VGi20UYgwGPH4850/CV1AS7lt5mUKbrJuXAN2xykEPlA17PdvS8JGYD
RNrl8NJo524ESMJb5YJlvKyXs9sCgYEA7j14Ofblfzr4Y/63ProxpZ4JHkxlzKGa
NOe6BNAvjyiZKRzyDxnd7NMY9shvgDv0mtl3o6QY19GOlYhBYwSUwZUSn/opdIIF
eMuApH9k77FTch+DV0h7VQYltgujE+yr6NirpUIv7Y4o5f2drS7rT8s3krGMZs/A
kwMfSQIHJ6cCgYA3Wi6Jx9N8EAe6hPybxaK6tH+Ldi4k3ZzzIMYjFaY1k73KGIpw
fuO2oRIAijBsxGa4iI+NebOSZ9fPZLLnlTKFQSooOqKNWTYgwhJnai4jN1GRhIpA
exhLFVAFSlYJNjx5/YN7NMBZKofrK7cjhhxEcIGStv+8QUzxARw25e+dswKBgBPn
GLsm8Cc/4u5foilgXrNqT3KziTGeMobG8Rhj2AVKq/juTR6L16loPUaomgAJgjbJ
giAunlCxVgsR9fxyroa5kHPC72GnVxOvVJDpf6IymzkGfu90w7DnsZDSyg3pELeE
GlrU+7IJ1UrZdCm6qLfiz0K3CHayVnExqpRr0fMzAoGAWQpRBcXojYdw2/3e8znb
Tab2krz9HPNCbFPcEwDE9Te57ejEBkKYNdhMzKnvQ5SOPiZDhjNHTAsBy/SRvcYS
UV9LON0HHY3L/dIVOfg0YVrM+/RsUNatdUwbdZTgvhZdTkiudLne25l1F3xpLyXZ
gVM0SkdAdMeNmluvfJbJz6A=
-----END PRIVATE KEY-----
";

fn key_file(private_key: &str) -> String {
    json!({
        "type": "service_account",
        "project_id": "peering-test",
        "client_email": "relay@peering-test.iam.gserviceaccount.com",
        "private_key": private_key,
        "token_uri": "https://oauth2.googleapis.com/token",
    })
    .to_string()
}

fn account() -> ServiceAccount {
    ServiceAccount::from_json(&key_file(TEST_ONLY_KEY)).expect("the test key parses")
}

fn decode_segment(segment: &str) -> serde_json::Value {
    let bytes = URL_SAFE_NO_PAD.decode(segment).expect("base64url");
    serde_json::from_slice(&bytes).expect("JSON")
}

#[test]
fn the_service_account_file_yields_its_project_and_token_endpoint() {
    let account = account();
    assert_eq!(account.project_id(), "peering-test");
    assert_eq!(account.token_uri(), "https://oauth2.googleapis.com/token");
}

#[test]
fn a_file_without_a_key_is_refused() {
    assert!(ServiceAccount::from_json(&key_file("not a key")).is_err());
    assert!(ServiceAccount::from_json("{}").is_err());
}

#[test]
fn the_assertion_has_three_parts() {
    let assertion = account().build_assertion(FCM_SCOPE, 1_000).expect("signs");
    assert_eq!(assertion.split('.').count(), 3);
}

#[test]
fn the_header_and_claims_are_the_ones_google_expects() {
    let assertion = account().build_assertion(FCM_SCOPE, 1_000).expect("signs");
    let parts: Vec<&str> = assertion.split('.').collect();
    assert_eq!(decode_segment(parts[0]), json!({"alg": "RS256", "typ": "JWT"}));
    assert_eq!(
        decode_segment(parts[1]),
        json!({
            "iss": "relay@peering-test.iam.gserviceaccount.com",
            "scope": FCM_SCOPE,
            "aud": "https://oauth2.googleapis.com/token",
            "iat": 1_000,
            "exp": 4_600,
        })
    );
}

#[test]
fn the_signature_verifies_with_the_public_half_of_the_key() {
    let account = account();
    let assertion = account.build_assertion(FCM_SCOPE, 1_000).expect("signs");
    let (signed, signature) = assertion.rsplit_once('.').expect("three parts");
    let signature = URL_SAFE_NO_PAD.decode(signature).expect("base64url");
    let public = UnparsedPublicKey::new(
        &RSA_PKCS1_2048_8192_SHA256,
        account.key_pair.public().as_ref(),
    );
    assert!(public.verify(signed.as_bytes(), &signature).is_ok());
    assert!(public.verify(b"tampered", &signature).is_err());
}

#[tokio::test]
async fn a_token_is_reused_until_45_minutes_have_passed() {
    let exchange = FakeTokenExchange::replying("ya29.first", 3600);
    let cache = AccessTokenCache::new(account(), FCM_SCOPE, exchange, FixedClock::at(1_000));
    assert_eq!(cache.access_token().await.unwrap(), "ya29.first");
    cache.clock.advance(2_699);
    assert_eq!(cache.access_token().await.unwrap(), "ya29.first");
    assert_eq!(cache.exchange.calls(), 1);
}

#[tokio::test]
async fn a_token_is_renewed_once_45_minutes_have_passed() {
    let exchange = FakeTokenExchange::replying("ya29.renewed", 3600);
    let cache = AccessTokenCache::new(account(), FCM_SCOPE, exchange, FixedClock::at(1_000));
    cache.access_token().await.unwrap();
    cache.clock.advance(2_700);
    cache.access_token().await.unwrap();
    assert_eq!(cache.exchange.calls(), 2);
    let assertion = cache.exchange.last_assertion().expect("an assertion was sent");
    let claims = assertion.split('.').nth(1).expect("claims");
    assert_eq!(decode_segment(claims)["iat"], 3_700);
}

#[tokio::test]
async fn a_shorter_lifetime_from_google_is_respected() {
    let exchange = FakeTokenExchange::replying("ya29.short", 600);
    let cache = AccessTokenCache::new(account(), FCM_SCOPE, exchange, FixedClock::at(1_000));
    cache.access_token().await.unwrap();
    cache.clock.advance(600);
    cache.access_token().await.unwrap();
    assert_eq!(cache.exchange.calls(), 2);
}

#[tokio::test]
async fn a_failed_exchange_is_reported_and_not_remembered() {
    let exchange = FakeTokenExchange::failing("invalid_grant");
    let cache = AccessTokenCache::new(account(), FCM_SCOPE, exchange, FixedClock::at(1_000));
    assert!(cache.access_token().await.is_err());
    assert!(cache.access_token().await.is_err());
    assert_eq!(cache.exchange.calls(), 2);
}

#[test]
fn a_token_reply_yields_the_token_and_its_lifetime() {
    let reply = parse_token_reply(200, r#"{"access_token":"ya29.a","expires_in":3599,"token_type":"Bearer"}"#)
        .expect("parses");
    assert_eq!(reply, TokenReply { access_token: "ya29.a".into(), expires_in: 3599 });
}

#[test]
fn a_refused_exchange_names_the_reason_google_gives() {
    let error = parse_token_reply(400, r#"{"error":"invalid_grant"}"#).unwrap_err();
    assert!(error.to_string().contains("invalid_grant"));
}

#[test]
fn a_200_without_a_token_is_refused() {
    assert!(parse_token_reply(200, r#"{"expires_in":3599}"#).is_err());
}
