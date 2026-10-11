//! Reads the two Play replies into `PlayPurchase`. Field names are UNVERIFIED; see the module header
//! in `play_api`.

use serde::Deserialize;

use super::{PlayPurchase, PurchaseState};
use crate::fcm_auth::BoxError;

pub fn purchase(product_id: &str, one_time: bool, body: &str) -> Result<PlayPurchase, BoxError> {
    if one_time {
        one_time_purchase(product_id, body)
    } else {
        subscription(product_id, body)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SubscriptionBody {
    subscription_state: String,
    #[serde(default)]
    line_items: Vec<LineItem>,
    external_account_identifiers: Option<ExternalAccountIdentifiers>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LineItem {
    product_id: String,
    expiry_time: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExternalAccountIdentifiers {
    obfuscated_external_account_id: Option<String>,
}

fn subscription(product_id: &str, body: &str) -> Result<PlayPurchase, BoxError> {
    let parsed: SubscriptionBody = serde_json::from_str(body)
        .map_err(|error| format!("subscription reply is not the expected JSON: {error}"))?;
    let state = subscription_state(&parsed.subscription_state)?;
    let item = parsed
        .line_items
        .iter()
        .find(|item| item.product_id == product_id)
        .ok_or("the subscription reply names no line item for the product")?;
    let expiry_unix = match &item.expiry_time {
        Some(text) => Some(rfc3339_unix(text).ok_or("expiryTime is not an RFC 3339 UTC time")?),
        None => None,
    };
    Ok(PlayPurchase {
        product_id: product_id.to_owned(),
        state,
        expiry_unix,
        obfuscated_account_id: parsed
            .external_account_identifiers
            .and_then(|ids| ids.obfuscated_external_account_id),
        is_lifetime: false,
    })
}

fn subscription_state(name: &str) -> Result<PurchaseState, BoxError> {
    Ok(match name {
        "SUBSCRIPTION_STATE_ACTIVE" => PurchaseState::Active,
        "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" => PurchaseState::InGrace,
        "SUBSCRIPTION_STATE_CANCELED" => PurchaseState::Canceled,
        "SUBSCRIPTION_STATE_ON_HOLD" => PurchaseState::OnHold,
        "SUBSCRIPTION_STATE_PAUSED" => PurchaseState::Paused,
        "SUBSCRIPTION_STATE_EXPIRED" => PurchaseState::Expired,
        "SUBSCRIPTION_STATE_PENDING" | "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED" => PurchaseState::Pending,
        other => return Err(format!("unknown subscriptionState {other}").into()),
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OneTimeBody {
    purchase_state: Option<u32>,
    obfuscated_external_account_id: Option<String>,
}

fn one_time_purchase(product_id: &str, body: &str) -> Result<PlayPurchase, BoxError> {
    let parsed: OneTimeBody = serde_json::from_str(body)
        .map_err(|error| format!("product reply is not the expected JSON: {error}"))?;
    let state = match parsed.purchase_state {
        Some(0) => PurchaseState::Active,
        Some(1) => PurchaseState::Canceled,
        Some(2) => PurchaseState::Pending,
        Some(other) => return Err(format!("unknown purchaseState {other}").into()),
        None => return Err("the product reply has no purchaseState".into()),
    };
    Ok(PlayPurchase {
        product_id: product_id.to_owned(),
        state,
        expiry_unix: None,
        obfuscated_account_id: parsed.obfuscated_external_account_id,
        is_lifetime: true,
    })
}

/// Seconds since the epoch for an RFC 3339 time in UTC, such as `2025-06-01T10:00:00.123Z`. The
/// fraction is read past and dropped, because a whole second is the precision an expiry needs.
pub fn rfc3339_unix(text: &str) -> Option<u64> {
    let text = text.strip_suffix('Z')?;
    let (date, time) = text.split_once('T')?;
    let mut date_parts = date.split('-');
    let year: i64 = date_parts.next()?.parse().ok()?;
    let month: i64 = date_parts.next()?.parse().ok()?;
    let day: i64 = date_parts.next()?.parse().ok()?;
    if date_parts.next().is_some() {
        return None;
    }
    let mut time_parts = time.split('.').next()?.split(':');
    let hour: i64 = time_parts.next()?.parse().ok()?;
    let minute: i64 = time_parts.next()?.parse().ok()?;
    let second: i64 = time_parts.next()?.parse().ok()?;
    if time_parts.next().is_some()
        || !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || !(0..24).contains(&hour)
        || !(0..60).contains(&minute)
        || !(0..=60).contains(&second)
    {
        return None;
    }
    let days = days_from_civil(year, month, day);
    u64::try_from(days * 86_400 + hour * 3_600 + minute * 60 + second).ok()
}

/// Days from 1970-01-01 to the given civil date (proleptic Gregorian).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month_from_march = (month + 9) % 12;
    let day_of_year = (153 * month_from_march + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}
