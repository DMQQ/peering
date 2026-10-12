//! Counts of how sessions end and why attempts fail, for the journal.
//!
//! Everything here is a number or a name from a closed set. No id, address, key, token or byte of
//! content passes through: the relay cannot read what it carries, and its log is not the place to
//! weaken that. The counters are process-wide because the events they count happen in four
//! unrelated tasks, and a handle threaded through all of them would buy nothing.

use std::io::ErrorKind;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tracing::info;

/// How often the summary line is written.
pub const SUMMARY_PERIOD: Duration = Duration::from_secs(600);

/// Average control-channel throughput past which a session with no UDP picture is taken to be
/// carrying its picture on the control stream. A bare control stream (TLS handshake, cursor
/// commands) sits far below this; video is orders of magnitude above it.
const TCP_FALLBACK_BYTES_PER_SECOND: u64 = 32 * 1024;

/// What a finished copy reported, if it was allowed to finish.
pub type CopyResult = Result<(u64, u64), std::io::Error>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndReason {
    /// An end hung up and the splice finished without an error.
    PeerClosed,
    QuotaExhausted,
    /// A read or write on a control socket failed, typically a reset.
    IoError,
    /// The relay was stopped while the splice was running.
    Shutdown,
}

impl EndReason {
    const ALL: [Self; 4] = [Self::PeerClosed, Self::QuotaExhausted, Self::IoError, Self::Shutdown];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::PeerClosed => "peer_closed",
            Self::QuotaExhausted => "quota_exhausted",
            Self::IoError => "io_error",
            Self::Shutdown => "shutdown",
        }
    }
}

/// Why a splice ended. The allowance wins over the copy's own result because the copy is dropped to
/// end the session, so its state at that moment says nothing about who left.
pub fn end_reason(spent: bool, copy: Option<&CopyResult>) -> EndReason {
    match (spent, copy) {
        (true, _) => EndReason::QuotaExhausted,
        (false, Some(Err(_))) => EndReason::IoError,
        (false, _) => EndReason::PeerClosed,
    }
}

/// The kind of a failed copy, which is a closed enum and carries no content.
pub fn error_kind(copy: Option<&CopyResult>) -> Option<ErrorKind> {
    match copy {
        Some(Err(error)) => Some(error.kind()),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlanTier {
    Free,
    Paid,
    Unlimited,
}

impl PlanTier {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Free => "free",
            Self::Paid => "paid",
            Self::Unlimited => "unlimited",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoPath {
    Udp,
    TcpFallback,
    None,
}

impl VideoPath {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Udp => "udp",
            Self::TcpFallback => "tcp_fallback",
            Self::None => "none",
        }
    }
}

/// UDP wins whenever a single picture datagram crossed. Otherwise a heavy control stream means the
/// picture went that way, which is a fallback that worked.
pub fn video_path(host_datagrams: u64, control_bytes: u64, seconds: u64) -> VideoPath {
    if host_datagrams > 0 {
        VideoPath::Udp
    } else if control_bytes / seconds.max(1) >= TCP_FALLBACK_BYTES_PER_SECOND {
        VideoPath::TcpFallback
    } else {
        VideoPath::None
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    HostNotRegistered,
    HostOffline,
    BadToken,
    BadProof,
    QuotaRefusedAtConnect,
    TimedOutWaitingForHost,
    /// A message this relay's protocol has no variant for, or a host and client on different versions.
    VersionMismatch,
    /// A message that did not parse for any reason other than an unknown variant.
    MalformedMessage,
    /// A session ended with an end that never sent a datagram to the shared video socket.
    UdpBindUnclaimed,
}

impl Refusal {
    const ALL: [Self; 9] = [
        Self::HostNotRegistered,
        Self::HostOffline,
        Self::BadToken,
        Self::BadProof,
        Self::QuotaRefusedAtConnect,
        Self::TimedOutWaitingForHost,
        Self::VersionMismatch,
        Self::MalformedMessage,
        Self::UdpBindUnclaimed,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::HostNotRegistered => "host_not_registered",
            Self::HostOffline => "host_offline",
            Self::BadToken => "bad_token",
            Self::BadProof => "bad_proof",
            Self::QuotaRefusedAtConnect => "quota_refused_at_connect",
            Self::TimedOutWaitingForHost => "timed_out_waiting_for_host",
            Self::VersionMismatch => "version_mismatch",
            Self::MalformedMessage => "malformed_message",
            Self::UdpBindUnclaimed => "udp_bind_unclaimed",
        }
    }

    /// Serde reports a message with an unknown `type` as "unknown variant"; that is a peer from a
    /// different version rather than garbage.
    pub fn for_unparseable(error: &impl std::fmt::Display) -> Self {
        if error.to_string().contains("unknown variant") {
            Self::VersionMismatch
        } else {
            Self::MalformedMessage
        }
    }
}

/// Counters since the last summary, plus the one gauge (active splices) that survives it.
pub struct Tally {
    allocated: AtomicU64,
    started: AtomicU64,
    active: AtomicU64,
    ended: [AtomicU64; EndReason::ALL.len()],
    refused: [AtomicU64; Refusal::ALL.len()],
    udp_unclaimed: AtomicU64,
}

/// The process-wide tally every module records into.
pub static TALLY: Tally = Tally::new();

/// What one summary line reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Summary {
    pub allocated: u64,
    pub started: u64,
    pub active: u64,
    pub ended: [u64; EndReason::ALL.len()],
    pub refused: [u64; Refusal::ALL.len()],
    pub udp_unclaimed: u64,
}

impl Summary {
    pub fn ended_by(&self, reason: EndReason) -> u64 {
        self.ended[reason as usize]
    }

    pub fn refused_for(&self, reason: Refusal) -> u64 {
        self.refused[reason as usize]
    }

    pub fn log(&self) {
        info!(
            sessions_allocated = self.allocated,
            sessions_started = self.started,
            active_splices = self.active,
            ended_peer_closed = self.ended_by(EndReason::PeerClosed),
            ended_quota_exhausted = self.ended_by(EndReason::QuotaExhausted),
            ended_io_error = self.ended_by(EndReason::IoError),
            ended_shutdown = self.ended_by(EndReason::Shutdown),
            refused_host_not_registered = self.refused_for(Refusal::HostNotRegistered),
            refused_host_offline = self.refused_for(Refusal::HostOffline),
            refused_bad_token = self.refused_for(Refusal::BadToken),
            refused_bad_proof = self.refused_for(Refusal::BadProof),
            refused_quota_refused_at_connect = self.refused_for(Refusal::QuotaRefusedAtConnect),
            refused_timed_out_waiting_for_host = self.refused_for(Refusal::TimedOutWaitingForHost),
            refused_version_mismatch = self.refused_for(Refusal::VersionMismatch),
            refused_malformed_message = self.refused_for(Refusal::MalformedMessage),
            failed_udp_bind_unclaimed = self.refused_for(Refusal::UdpBindUnclaimed),
            udp_datagrams_unclaimed = self.udp_unclaimed,
            "relay summary since the last one"
        );
    }
}

impl Tally {
    pub const fn new() -> Self {
        Self {
            allocated: AtomicU64::new(0),
            started: AtomicU64::new(0),
            active: AtomicU64::new(0),
            ended: [const { AtomicU64::new(0) }; EndReason::ALL.len()],
            refused: [const { AtomicU64::new(0) }; Refusal::ALL.len()],
            udp_unclaimed: AtomicU64::new(0),
        }
    }

    pub fn session_allocated(&self) {
        self.allocated.fetch_add(1, Ordering::Relaxed);
    }

    pub fn splice_started(&self) {
        self.started.fetch_add(1, Ordering::Relaxed);
        self.active.fetch_add(1, Ordering::Relaxed);
    }

    pub fn splice_ended(&self, reason: EndReason) {
        self.ended[reason as usize].fetch_add(1, Ordering::Relaxed);
        let _ = self
            .active
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |now| Some(now.saturating_sub(1)));
    }

    /// Called once as the process stops: every splice still running ends here, since none of them
    /// will get to say so.
    pub fn shutting_down(&self) {
        let running = self.active.swap(0, Ordering::Relaxed);
        self.ended[EndReason::Shutdown as usize].fetch_add(running, Ordering::Relaxed);
    }

    pub fn refused(&self, reason: Refusal) {
        self.refused[reason as usize].fetch_add(1, Ordering::Relaxed);
    }

    pub fn udp_unclaimed(&self) {
        self.udp_unclaimed.fetch_add(1, Ordering::Relaxed);
    }

    /// Reads and zeroes the counters. The active gauge is read, not zeroed.
    pub fn take_summary(&self) -> Summary {
        Summary {
            allocated: self.allocated.swap(0, Ordering::Relaxed),
            started: self.started.swap(0, Ordering::Relaxed),
            active: self.active.load(Ordering::Relaxed),
            ended: std::array::from_fn(|i| self.ended[i].swap(0, Ordering::Relaxed)),
            refused: std::array::from_fn(|i| self.refused[i].swap(0, Ordering::Relaxed)),
            udp_unclaimed: self.udp_unclaimed.swap(0, Ordering::Relaxed),
        }
    }
}

impl Default for Tally {
    fn default() -> Self {
        Self::new()
    }
}

/// Writes the summary line every [`SUMMARY_PERIOD`], starting one period from now, so a relay that
/// has gone quiet still says so.
pub async fn report_forever() {
    let mut ticks = tokio::time::interval_at(tokio::time::Instant::now() + SUMMARY_PERIOD, SUMMARY_PERIOD);
    loop {
        ticks.tick().await;
        TALLY.take_summary().log();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn failed() -> CopyResult {
        Err(std::io::Error::from(ErrorKind::ConnectionReset))
    }

    #[test]
    fn running_out_of_allowance_outranks_how_the_copy_finished() {
        assert_eq!(end_reason(true, Some(&failed())), EndReason::QuotaExhausted);
        assert_eq!(end_reason(true, None), EndReason::QuotaExhausted);
    }

    #[test]
    fn a_failed_copy_is_an_io_error_and_a_finished_one_is_a_peer_closing() {
        assert_eq!(end_reason(false, Some(&failed())), EndReason::IoError);
        assert_eq!(end_reason(false, Some(&Ok((1, 2)))), EndReason::PeerClosed);
        assert_eq!(error_kind(Some(&failed())), Some(ErrorKind::ConnectionReset));
        assert_eq!(error_kind(Some(&Ok((1, 2)))), None);
    }

    #[test]
    fn any_udp_picture_datagram_makes_the_path_udp() {
        assert_eq!(video_path(1, 10_000_000, 10), VideoPath::Udp);
    }

    #[test]
    fn a_heavy_control_stream_without_udp_is_a_tcp_fallback() {
        assert_eq!(video_path(0, 10 * 1024 * 1024, 10), VideoPath::TcpFallback);
    }

    #[test]
    fn a_quiet_control_stream_without_udp_means_no_video_at_all() {
        assert_eq!(video_path(0, 8 * 1024, 10), VideoPath::None);
        assert_eq!(video_path(0, 0, 0), VideoPath::None);
    }

    #[test]
    fn an_unknown_variant_is_a_version_mismatch_and_other_garbage_is_not() {
        #[derive(Debug, serde::Deserialize)]
        #[serde(tag = "type")]
        enum Known {
            Ping,
        }
        let unknown = serde_json::from_str::<Known>(r#"{"type":"fromTheFuture"}"#).unwrap_err();
        let garbage = serde_json::from_str::<Known>("not json").unwrap_err();
        assert_eq!(Refusal::for_unparseable(&unknown), Refusal::VersionMismatch);
        assert_eq!(Refusal::for_unparseable(&garbage), Refusal::MalformedMessage);
    }

    #[test]
    fn a_summary_counts_since_the_last_one_and_keeps_active_splices() {
        let tally = Tally::new();
        tally.session_allocated();
        tally.splice_started();
        tally.splice_started();
        tally.splice_ended(EndReason::IoError);
        tally.refused(Refusal::BadToken);
        tally.refused(Refusal::BadToken);
        tally.udp_unclaimed();

        let first = tally.take_summary();
        assert_eq!((first.allocated, first.started, first.active), (1, 2, 1));
        assert_eq!(first.ended_by(EndReason::IoError), 1);
        assert_eq!(first.ended_by(EndReason::PeerClosed), 0);
        assert_eq!(first.refused_for(Refusal::BadToken), 2);
        assert_eq!(first.udp_unclaimed, 1);

        let second = tally.take_summary();
        assert_eq!((second.allocated, second.started, second.active), (0, 0, 1));
        assert_eq!(second.refused_for(Refusal::BadToken), 0);
        assert_eq!(second.udp_unclaimed, 0);
    }

    #[test]
    fn shutting_down_ends_every_running_splice_as_a_shutdown() {
        let tally = Tally::new();
        tally.splice_started();
        tally.splice_started();

        tally.shutting_down();

        let summary = tally.take_summary();
        assert_eq!(summary.ended_by(EndReason::Shutdown), 2);
        assert_eq!(summary.active, 0);
    }

    #[test]
    fn ending_more_splices_than_started_never_underflows_the_gauge() {
        let tally = Tally::new();
        tally.splice_ended(EndReason::PeerClosed);
        assert_eq!(tally.take_summary().active, 0);
    }

    #[test]
    fn every_reason_has_a_distinct_name() {
        let mut names: Vec<_> = Refusal::ALL.iter().map(|r| r.as_str()).collect();
        names.extend(EndReason::ALL.iter().map(|r| r.as_str()));
        let count = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), count);
    }
}
