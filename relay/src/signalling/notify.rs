//! A registered Mac asking the relay to push to a phone.

use std::sync::Arc;
use std::time::Instant;

use tokio::sync::mpsc;
use tracing::warn;

use super::{field_too_long, unix_now, ConnectionState, Settings};
use crate::activity::{self, ActivityPush, ActivityRefusal};
use crate::apns::{PushAction, PushRoute};
use crate::protocol::ServerMessage;
use crate::push::{self, PushTarget};
use crate::redact::tag;
use crate::stats::{ActivityOutcome, TALLY};

/// The only categories a Mac may name: the ones the phone registers for an agent approval, and for
/// the notice that a turn finished.
const AGENT_APPROVAL_CATEGORY_PREFIX: &str = "peering.agent.approval.";
const AGENT_FINISHED_CATEGORY: &str = "peering.agent.finished";

/// Hex characters. An APNs token is 64; an FCM token is about 160 characters before it is hex
/// encoded behind a `fcm:` prefix.
pub(super) const MAX_DEVICE_TOKEN_HEX: usize = 1024;

pub(super) fn is_agent_category(category: &str) -> bool {
    category.starts_with(AGENT_APPROVAL_CATEGORY_PREFIX) || category == AGENT_FINISHED_CATEGORY
}

/// An action needs all three parts and a category only the app registered; anything else is
/// dropped rather than forwarded under the phone's name.
fn push_action<'a>(
    category: Option<&'a str>,
    session_id: Option<&'a str>,
    approval_id: Option<&'a str>,
    options: &'a [String],
) -> Option<PushAction<'a>> {
    match (category, session_id, approval_id) {
        (Some(category), Some(session_id), Some(approval_id)) if is_agent_category(category) => {
            Some(PushAction { category, session_id, approval_id, options })
        }
        _ => None,
    }
}

pub(super) struct DeviceNotice {
    pub device_token: String,
    pub title: String,
    pub body: String,
    pub source: Option<String>,
    pub category: Option<String>,
    pub session_id: Option<String>,
    pub approval_id: Option<String>,
    pub options: Option<Vec<String>>,
}

/// A banner holds about four buttons, and each title is cut by the phone, so more is noise.
const MAX_OPTIONS: usize = 4;
const MAX_OPTION_BYTES: usize = 160;

impl DeviceNotice {
    fn fits(&self) -> bool {
        let within = |field: &Option<String>, limit: usize| field.as_ref().is_none_or(|text| text.len() <= limit);
        self.device_token.len() <= MAX_DEVICE_TOKEN_HEX
            && self.title.len() <= 256
            && self.body.len() <= 512
            && within(&self.source, 128)
            && within(&self.category, 128)
            && within(&self.session_id, 128)
            && within(&self.approval_id, 256)
            && self.options.as_ref().is_none_or(|options| {
                options.len() <= MAX_OPTIONS && options.iter().all(|option| option.len() <= MAX_OPTION_BYTES)
            })
    }

    fn action(&self) -> Option<PushAction<'_>> {
        push_action(self.category.as_deref(), self.session_id.as_deref(), self.approval_id.as_deref(), self.options.as_deref().unwrap_or(&[]))
    }
}

fn unauthorized() -> ServerMessage {
    ServerMessage::error("unauthorized", "only registered hosts may request push notifications")
}

/// `notifyDevice`. A service that is not configured drops the push, as it always has.
pub(super) fn notify_device(
    notice: DeviceNotice,
    settings: &Settings,
    state: &mut ConnectionState,
) -> Option<ServerMessage> {
    // The relay's own record of who asked, so a tap can only ever open the Mac that sent it.
    let Some(host_id) = state.registered_as.clone() else { return Some(unauthorized()) };
    if !notice.fits() {
        return Some(field_too_long());
    }
    if !state.push_limiter.allow(Instant::now()) {
        warn!(host_id = %tag(&host_id), "notifyDevice over its budget, dropped");
        return None;
    }
    match push::target_for(&notice.device_token) {
        PushTarget::Fcm(token) => {
            if let Some(fcm) = settings.fcm.as_ref().map(Arc::clone) {
                tokio::spawn(async move {
                    let route = PushRoute { host_id: &host_id, source: notice.source.as_deref(), action: notice.action() };
                    if let Err(error) = fcm.send(&token, &notice.title, &notice.body, Some(route)).await {
                        warn!(%error, "FCM notification failed");
                    }
                });
            }
        }
        PushTarget::Apns(token) => {
            if let Some(apns) = settings.apns.as_ref().map(Arc::clone) {
                tokio::spawn(async move {
                    let route = PushRoute { host_id: &host_id, source: notice.source.as_deref(), action: notice.action() };
                    if let Err(error) = apns.send(&token, &notice.title, &notice.body, Some(route)).await {
                        warn!(%error, "APNs notification failed");
                    }
                });
            }
        }
    }
    None
}

pub(super) fn notify_activity_from_host(
    push: ActivityPush,
    self_tx: &mpsc::Sender<ServerMessage>,
    settings: &Settings,
    state: &mut ConnectionState,
) -> Option<ServerMessage> {
    if state.registered_as.is_none() {
        return Some(unauthorized());
    }
    notify_activity(push, self_tx, settings, state)
}

/// Validates and sends one Live Activity push. The APNs call runs in the background; a failure
/// there reaches the host as `activityRefused` on the same socket.
fn notify_activity(
    push: ActivityPush,
    self_tx: &mpsc::Sender<ServerMessage>,
    settings: &Settings,
    state: &mut ConnectionState,
) -> Option<ServerMessage> {
    let request_id = push.request_id.clone().filter(|id| id.chars().count() <= activity::MAX_REQUEST_ID_CHARS);
    let refuse = |refusal: ActivityRefusal| {
        TALLY.activity(ActivityOutcome::refused(refusal));
        Some(ServerMessage::ActivityRefused { reason: refusal, request_id: request_id.clone() })
    };
    let request = match activity::build(&push, unix_now()) {
        Ok(request) => request,
        Err(refusal) => return refuse(refusal),
    };
    if !matches!(push::target_for(&push.activity_token), PushTarget::Apns(_)) {
        return refuse(ActivityRefusal::InvalidToken);
    }
    let now = Instant::now();
    if !state.activity_limiter.allow(&push.activity_token, now) || !settings.activity_budget.allow(&push.activity_token, now) {
        TALLY.activity(ActivityOutcome::DroppedRate);
        return None;
    }
    let Some(apns) = settings.apns.as_ref().map(Arc::clone) else {
        return refuse(ActivityRefusal::Unavailable);
    };
    let reply = self_tx.clone();
    tokio::spawn(async move {
        match apns.send_activity(&push.activity_token, push.environment, &request).await {
            Ok(()) => TALLY.activity(ActivityOutcome::Sent),
            Err(failure) => {
                let refusal = failure.refusal();
                TALLY.activity(ActivityOutcome::refused(refusal));
                let _ = reply.try_send(ServerMessage::ActivityRefused { reason: refusal, request_id });
            }
        }
    });
    None
}
