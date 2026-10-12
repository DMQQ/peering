//! The control relay: two connections in, one pipe out.
//!
//! This is deliberately the least clever code in the project. It reads a token, finds the session,
//! waits for the other half, and copies bytes until one side stops, or until the plan the session
//! was allocated on has spent its relay allowance for the window. It cannot read what it copies,
//! because what it copies is a TLS session belonging to the two ends — see `TLSConfig` and the
//! pinning in `PeerPinning.swift` on the Swift side, which is where the actual authorization
//! happens.
//!
//! The token arrives in the clear, before TLS starts. That is not an oversight: the token is what
//! tells us where the TLS handshake should be carried, so it necessarily precedes it. See the
//! module comment on `session.rs` for why that is safe.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::time::timeout;
use tracing::{debug, info, warn};

use crate::counted_stream::{Activity, CountedStream, EndWatch, Side};
use crate::redact::tag;
use crate::session::{Join, Registry, Token};
use crate::stats::{self, EndReason, Refusal, TALLY};

/// How long a connection may sit without presenting a token. Long enough to survive a slow start,
/// short enough that an idle socket cannot be used to hold resources.
const TOKEN_DEADLINE: Duration = Duration::from_secs(5);

/// Sockets that may be waiting to present a token at once. Established splices do not count: the permit is returned the moment the token is read.
const MAX_UNAUTHENTICATED: usize = 512;

/// Without a pause a persistent accept error (descriptor exhaustion) turns this loop into a spinning core and a log flood.
const ACCEPT_ERROR_BACKOFF: Duration = Duration::from_millis(50);

/// `idle_window` is how long a splice may carry no bytes in either direction before it is ended;
/// zero disables the check.
pub async fn serve(listener: TcpListener, registry: Arc<Registry>, idle_window: Duration) {
    let waiting = Arc::new(tokio::sync::Semaphore::new(MAX_UNAUTHENTICATED));
    info!(addr = %listener.local_addr().map(|a| a.to_string()).unwrap_or_default(), "control relay listening");

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                // Nagle off, on both halves of every splice. This one listener accepts *both*
                // ends of a session — the connection that waits and the one handed to it — so
                // setting it here covers the pair, and `copy_bidirectional` below inherits it.
                //
                // This is not a tuning preference. What crosses here is a coalesced 60 Hz
                // command stream in small writes, and Nagle holds a partial segment until the
                // previous one is acknowledged. On a path whose RTT is tens of milliseconds
                // that is a round trip added to every cursor position, which is the class of
                // delay the user feels most directly. It cannot be fixed above us either: the
                // buffering happens below the copy, in the kernel.
                //
                // A failure here costs latency, not correctness, so it is logged and carried
                // on rather than closing a connection that would otherwise work.
                if let Err(error) = stream.set_nodelay(true) {
                    warn!(%error, "could not disable Nagle on a control connection");
                }

                let Ok(permit) = Arc::clone(&waiting).try_acquire_owned() else {
                    warn!("refused a control connection: too many are waiting for a token");
                    continue;
                };

                let registry = Arc::clone(&registry);
                tokio::spawn(async move {
                    if let Err(error) = handle(stream, registry, permit, idle_window).await {
                        debug!(%error, "control connection ended");
                    }
                });
            }
            // A failed accept is about this connection, not the listener — a file-descriptor
            // exhaustion or a peer that vanished mid-handshake. Logging and carrying on is right;
            // tearing the listener down would take every other session with it.
            Err(error) => {
                warn!(%error, "control listener could not accept");
                tokio::time::sleep(ACCEPT_ERROR_BACKOFF).await;
            }
        }
    }
}

async fn handle(
    mut stream: TcpStream,
    registry: Arc<Registry>,
    waiting: tokio::sync::OwnedSemaphorePermit,
    idle_window: Duration,
) -> std::io::Result<()> {
    // No buffering here, and none needed: this is the only read this side ever does. Everything
    // after it belongs to TLS.
    let mut token: Token = [0u8; 16];
    timeout(TOKEN_DEADLINE, stream.read_exact(&mut token))
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "no token presented"))??;
    drop(waiting);

    // Looked up before joining, for the reason the client id used to be: the registry still holds
    // the session at this point, and what the splice is metered on has to be in hand before the
    // session that carries it can be superseded or swept. A token the registry does not know is not
    // spliced at all, and a token whose session has gone is the same answer: there is nothing to
    // charge, so there is nothing to carry.
    let Some(account) = registry.account_for_token(&token).await else {
        TALLY.refused(Refusal::BadToken);
        return Ok(());
    };

    let Some(join) = registry.join_control(&token, stream).await else {
        // Not a token we issued, or one that has already been used or swept. Closed without a
        // reply, so a probe learns nothing about whether the session exists.
        TALLY.refused(Refusal::BadToken);
        return Ok(());
    };

    let Join::Waiting { mine, peer } = join else {
        debug!("control connection handed to its peer");
        return Ok(());
    };

    // Waiting for the peer is deliberately unbounded. The bound that matters is the session's own
    // lifetime: when the sweep takes an abandoned session it drops the sender, this await fails,
    // and the socket closes. A second timeout here would only duplicate that with a second number
    // to keep in step.
    let Ok(theirs) = peer.await else {
        TALLY.refused(Refusal::TimedOutWaitingForHost);
        info!(
            reason = Refusal::TimedOutWaitingForHost.as_str(),
            "session was swept before the peer connected; the other end never arrived"
        );
        return Ok(());
    };

    debug!("splicing");

    // The clock starts here, where both ends are present and bytes are about to move, rather than
    // at allocation: the seconds between a phone asking for a Mac and its two ends turning up are
    // not relay time, and a meter that ran from allocation would charge for them.
    let mut meter = account.start();
    let period = meter.period();
    // Delayed by a whole period rather than fired at once, which is what `interval` would do: the
    // first charge of a session should be for time it has actually spent, not a second of it at the
    // instant it opened. The instant is tokio's rather than the standard library's, and named in
    // full because the two types cannot be mixed up quietly: the timer is driven by the runtime's
    // clock, which is the one the interval is measured against.
    let mut ticks =
        tokio::time::interval_at(tokio::time::Instant::now() + period, period);

    // Pinned and polled through `&mut`, rather than rebuilt on each turn of the loop below: a
    // `copy_bidirectional` created fresh per iteration would start again with the buffers it had
    // already filled, and bytes read from one end but not yet written to the other would be lost
    // every time a tick was handled.
    let control_bytes = Arc::new(AtomicU64::new(0));
    let first_to_end = Arc::new(EndWatch::default());
    let activity = Arc::new(Activity::new());
    let mut mine = CountedStream::new(mine, Arc::clone(&control_bytes))
        .watched(Arc::clone(&first_to_end), Side::First)
        .active(Arc::clone(&activity));
    let mut theirs = CountedStream::new(theirs, Arc::clone(&control_bytes))
        .watched(Arc::clone(&first_to_end), Side::Second)
        .active(Arc::clone(&activity));
    let splice = tokio::io::copy_bidirectional(&mut mine, &mut theirs);
    tokio::pin!(splice);

    // Charges the client as the splice runs, and ends the session once the plan's allowance for the
    // window is gone. The copy result is discarded on purpose: a session ending is the normal case,
    // not an error worth logging at a level anyone reads.
    //
    // **Dropping the copy is how the session is ended**, and it is worth being honest about what
    // that costs: the buffers go with it, so a few kilobytes that were read from one end and not
    // yet written to the other are dropped on the floor and the two ends see a connection that
    // closed rather than one that was told why. There is nowhere to tell them why: everything
    // after the token is a TLS session this process cannot write into, and the client's signalling
    // socket is a different connection that may already be closed. The app finds out the way it
    // finds out about any dropped control connection, and the next attempt is refused at
    // `ConnectToHost` with `quotaExceeded`, which is where the reason belongs.
    //
    // `biased` so that the copy is looked at first every time round. The two arms can be ready at
    // once, and which of them is chosen decides whether a session that has just finished is
    // reported as one that ran out of allowance, which is a distinction the log line below exists
    // to make. Polling the work before the clock is also the order the two matter in.
    let mut spent = false;
    let mut idle = false;
    let mut copied = None;
    let spliced_at = std::time::Instant::now();
    TALLY.splice_started();
    loop {
        tokio::select! {
            biased;
            result = &mut splice => {
                copied = Some(result);
                break;
            }
            _ = ticks.tick() => {
                // **Said on every tick, not once at the start.** The sweep retires a session whose
                // registry entry has not been touched for the TTL, and the only thing that used to
                // touch it was the join at the beginning. A session that was working perfectly was
                // therefore swept five minutes in, taking its video routes with it and leaving the
                // control connection running, which is a picture that stops while everything else
                // still works. The tick is the only thing here that knows the session is doing
                // work, so it is the thing that has to say so.
                registry.touch(&token).await;
                // Charged only up to the last byte that crossed, so a stalled connection stops
                // costing the moment it stalls. A live one is at most a ping behind.
                if meter.charge_through(activity.last()) == Some(0) {
                    spent = true;
                    break;
                }
            }
            // A connection that has stalled bills nothing from the last byte onward and is ended
            // once the window passes. Armed afresh each turn, so traffic simply moves the deadline.
            _ = tokio::time::sleep(idle_left(&activity, idle_window)), if !idle_window.is_zero() => {
                if activity.idle_at(std::time::Instant::now()) >= idle_window {
                    meter.stop_at(activity.last());
                    idle = true;
                    break;
                }
            }
        }
    }

    // Released so the token cannot be presented again. Without this a token stays valid for the
    // rest of its TTL, and a leaked one could hold a splice open.
    let video = registry.release(&token).await;
    let tier = meter.tier();

    // The last stretch, which is whatever has passed since the previous charge. Taken here rather
    // than left to the meter's own drop so that the number billed is the number on the line below;
    // the drop is what covers the paths that never reach this one, and charging is cumulative, so
    // the two together cannot bill a second twice. Paid clients are charged the same way and are
    // never ended by it: their plan answers `None` to the question this asks.
    let left = meter.charge_through(activity.last());

    if spent {
        // The only line that says a session was cut off for money rather than by one of its ends:
        // without it, a client that spent its allowance and a client that hung up look identical in
        // the log, and the question "why was I disconnected" has no answer in it.
        info!(
            client_id = %tag(meter.client_id()),
            "session ended: the plan's relay allowance for this window is spent"
        );
    } else {
        debug!(
            client_id = %tag(meter.client_id()),
            remaining_secs = ?left,
            "relay usage recorded"
        );
    }

    let reason = stats::end_reason(spent, idle, copied.as_ref());
    TALLY.splice_ended(reason);
    let closed_first = match (reason, first_to_end.first_to_end()) {
        (EndReason::QuotaExhausted | EndReason::IdleTimeout, _) | (_, None) => "unknown",
        (_, Some(Side::First)) => "first_joiner",
        (_, Some(Side::Second)) => "second_joiner",
    };

    // One line per relayed session, kept at info: a session whose picture never crossed the video
    // socket is how a network that blocks UDP shows up here, and nothing else in the log says so.
    // `control_bytes` is large when the picture travelled on the control channel instead, so `video_over_udp = false` with a large count is a fallback that worked, not a blocked network.
    //
    // `closed_first` names sockets by arrival order because the relay cannot tell a phone from a Mac
    // here. `session_retired_early` means the registry had already dropped the session (swept or
    // superseded), so the video fields are zero for want of a count rather than for want of video.
    let session_retired_early = video.is_none();
    let video = video.unwrap_or_default();
    let seconds = spliced_at.elapsed().as_secs();
    let control_total = control_bytes.load(Ordering::Relaxed);
    let path = stats::video_path(video.from_host_datagrams, control_total, seconds);
    let first_video_ms = video
        .first_from_host
        .map(|at| at.saturating_duration_since(spliced_at).as_millis() as u64);
    if !session_retired_early && (!video.client_bound || !video.host_bound) {
        TALLY.refused(Refusal::UdpBindUnclaimed);
    }
    info!(
        seconds,
        video_over_udp = video.from_host_datagrams > 0,
        video_datagrams_from_host = video.from_host_datagrams,
        video_bytes_from_host = video.from_host_bytes,
        video_datagrams_from_client = video.from_client_datagrams,
        control_bytes = control_total,
        end_reason = reason.as_str(),
        closed_first,
        io_error_kind = ?stats::error_kind(copied.as_ref()),
        plan = tier.as_str(),
        video_path = path.as_str(),
        first_video_ms = ?first_video_ms,
        udp_client_bound = video.client_bound,
        udp_host_bound = video.host_bound,
        session_retired_early,
        "relayed session ended"
    );

    debug!("splice finished");
    Ok(())
}

/// How long until the splice would be idle for `window` if nothing else crossed. Never zero, so a
/// deadline already passed is re-checked on the next turn instead of spinning.
fn idle_left(activity: &Activity, window: Duration) -> Duration {
    window
        .saturating_sub(activity.idle_at(std::time::Instant::now()))
        .max(Duration::from_millis(1))
}
