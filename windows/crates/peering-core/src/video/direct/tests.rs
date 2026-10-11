use super::*;
use crate::fakes::clock::FakeClock;
use crate::ports::clock::Clock;

fn address(last_octet: u8, port: u16) -> SocketAddr {
    SocketAddr::from(([192, 168, 1, last_octet], port))
}

/// Runs the schedule from the clock's current time, advancing it to each due instant, and records what was due and when.
fn run_until(knocker: &mut DirectPathKnocker, clock: &FakeClock, end: f64) -> Vec<(f64, Vec<ProbeAction>)> {
    let mut log = Vec::new();
    while clock.now_seconds() <= end {
        let actions = knocker.due_probes(clock.now_seconds());
        if !actions.is_empty() {
            log.push((clock.now_seconds(), actions));
        }
        clock.advance(0.001);
    }
    log
}

fn probe_times(log: &[(f64, Vec<ProbeAction>)]) -> Vec<f64> {
    log.iter().filter(|(_, actions)| actions.iter().any(|a| matches!(a, ProbeAction::SendProbe(_)))).map(|(at, _)| *at).collect()
}

#[test]
fn nothing_is_sent_before_the_relay_has_given_an_address() {
    let clock = FakeClock::new(0.0, 0);
    let mut knocker = DirectPathKnocker::new();
    let log = run_until(&mut knocker, &clock, 1.0);
    assert!(probe_times(&log).is_empty());
    assert_eq!(knocker.state(), DirectPathState::NotTried);
}

#[test]
fn the_first_attempt_asks_the_relay_for_the_address() {
    let mut knocker = DirectPathKnocker::new();
    assert_eq!(knocker.due_probes(0.0), vec![ProbeAction::AskRelay]);
}

#[test]
fn an_address_from_the_relay_starts_probing_that_address() {
    let clock = FakeClock::new(0.0, 0);
    let mut knocker = DirectPathKnocker::new();
    knocker.due_probes(0.0);
    knocker.on_peer_address(address(9, 5000));
    assert_eq!(knocker.state(), DirectPathState::Probing);
    clock.advance(0.25);
    assert_eq!(knocker.due_probes(clock.now_seconds()), vec![ProbeAction::SendProbe(address(9, 5000))]);
    assert_eq!(knocker.video_destination(), None);
}

#[test]
fn the_first_twelve_attempts_are_spaced_250_milliseconds_apart() {
    let clock = FakeClock::new(0.0, 0);
    let mut knocker = DirectPathKnocker::new();
    knocker.on_peer_address(address(9, 5000));
    let times = probe_times(&run_until(&mut knocker, &clock, 3.0));
    assert_eq!(times.len(), 12);
    for pair in times.windows(2) {
        assert!((pair[1] - pair[0] - 0.25).abs() < 0.002, "gap {:?}", pair);
    }
}

#[test]
fn after_the_fast_attempts_the_cadence_is_five_seconds() {
    let clock = FakeClock::new(0.0, 0);
    let mut knocker = DirectPathKnocker::new();
    knocker.on_peer_address(address(9, 5000));
    let times = probe_times(&run_until(&mut knocker, &clock, 12.0));
    let slow: Vec<f64> = times.windows(2).skip(11).map(|pair| pair[1] - pair[0]).collect();
    assert!(!slow.is_empty());
    for gap in slow {
        assert!((gap - 5.0).abs() < 0.002, "gap {gap}");
    }
}

#[test]
fn the_relay_is_asked_again_on_every_twelfth_attempt() {
    let clock = FakeClock::new(0.0, 0);
    let mut knocker = DirectPathKnocker::new();
    knocker.on_peer_address(address(9, 5000));
    let asks = run_until(&mut knocker, &clock, 80.0)
        .iter()
        .filter(|(_, actions)| actions.contains(&ProbeAction::AskRelay))
        .count();
    assert_eq!(asks, 3);
}

#[test]
fn an_authenticated_datagram_opens_the_path_to_its_source() {
    let mut knocker = DirectPathKnocker::new();
    knocker.on_peer_address(address(9, 5000));
    knocker.on_authenticated_datagram(address(10, 6000));
    assert_eq!(knocker.state(), DirectPathState::Open);
    assert_eq!(knocker.video_destination(), Some(address(10, 6000)));
}

#[test]
fn opening_ends_the_fast_knocking_and_probes_the_open_address_at_once() {
    let clock = FakeClock::new(0.0, 0);
    let mut knocker = DirectPathKnocker::new();
    knocker.on_peer_address(address(9, 5000));
    knocker.due_probes(0.0);
    clock.advance(0.1);
    knocker.on_authenticated_datagram(address(10, 6000));
    assert_eq!(knocker.due_probes(clock.now_seconds()), vec![ProbeAction::SendProbe(address(10, 6000))]);
    let times = probe_times(&run_until(&mut knocker, &clock, 20.0));
    for pair in times.windows(2) {
        assert!((pair[1] - pair[0] - 5.0).abs() < 0.002);
    }
}

#[test]
fn a_later_source_takes_over_as_the_destination() {
    let mut knocker = DirectPathKnocker::new();
    knocker.on_authenticated_datagram(address(10, 6000));
    knocker.on_authenticated_datagram(address(11, 6001));
    assert_eq!(knocker.video_destination(), Some(address(11, 6001)));
}

#[test]
fn an_address_from_the_relay_does_not_close_an_open_path() {
    let mut knocker = DirectPathKnocker::new();
    knocker.on_authenticated_datagram(address(10, 6000));
    knocker.on_peer_address(address(9, 5000));
    assert_eq!(knocker.state(), DirectPathState::Open);
}
