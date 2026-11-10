//! Lets the per-pass pumps rest while no phone is connected, and pick their own pace again when one is.

use std::time::Duration;

use peering_core::supervision::pass_interval_seconds;
use tokio::sync::Notify;
use tokio::time::{sleep, Interval};

use super::shared::Shared;

/// Call after `ticks.tick()`. With no phone connected it sleeps out the rest of the idle interval and restarts `ticks`;
/// with one connected it returns at once.
pub(super) async fn rest_while_idle(shared: &Shared, ticks: &mut Interval) {
    rest(shared, ticks, None).await;
}

/// As `rest_while_idle`, but a command from the window ends the rest early.
pub(super) async fn rest_while_idle_unless_commanded(shared: &Shared, ticks: &mut Interval) {
    let wake = shared.wake.clone();
    rest(shared, ticks, Some(&wake)).await;
}

async fn rest(shared: &Shared, ticks: &mut Interval, wake: Option<&Notify>) {
    let busy = ticks.period().as_secs_f64();
    let phone_connected = !shared.lock().sessions.is_empty();
    let gap = pass_interval_seconds(busy, phone_connected);
    if gap <= busy {
        return;
    }
    let pause = sleep(Duration::from_secs_f64(gap - busy));
    match wake {
        Some(wake) => tokio::select! {
            () = pause => {}
            () = wake.notified() => {}
        },
        None => pause.await,
    }
    ticks.reset();
}
