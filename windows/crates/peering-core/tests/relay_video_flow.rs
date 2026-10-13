//! The host's video lanes and direct path: key grants, fallback to the control connection, chunked pictures, and the
//! knock toward the client's address. No sockets; time is passed in explicitly.

mod common;

use std::net::SocketAddr;

use common::{relay_token, picture};
use peering_core::video::coordinator::VideoOutput;
use peering_core::video::direct::{DirectPathKnocker, DirectPathState, ProbeAction};
use peering_core::video::lane::{LaneSend, Random, VideoLane};
use peering_wire::chunks::{Reassembler, MAX_REASSEMBLED};
use peering_wire::fallback::HostAnswer;
use peering_wire::framing::MessageKind;
use peering_wire::handshake::{VideoKeyGrant, VideoTransportKind, VideoTransportRequest};
use peering_wire::sealing::{Direction, Opener, TOKEN_SIZE};

struct RepeatingBytes(u8);

impl Random for RepeatingBytes {
    fn fill(&mut self, buffer: &mut [u8]) -> bool {
        buffer.fill(self.0);
        true
    }
}

#[test]
fn a_video_key_request_is_answered_with_a_grant_the_client_can_open_frames_with() {
    let mut lane = VideoLane::new(relay_token().0);
    let grant_frame = lane.answer_key_request(&mut RepeatingBytes(0x42)).expect("the grant is encoded");
    assert_eq!(grant_frame.kind, MessageKind::VideoKey);
    let grant: VideoKeyGrant = serde_json::from_slice(&grant_frame.payload).expect("grant decodes");
    assert_eq!(grant.secret.len(), 32);

    let sends = lane.send(&VideoOutput::Frame(picture(1, 300)), 1.0).expect("a frame is sealed");
    let datagram = match sends.as_slice() {
        [LaneSend::Datagram(bytes)] => bytes.clone(),
        other => panic!("expected one datagram, got {other:?}"),
    };
    let mut opener = Opener::new(&grant.secret, Direction::HostToClient).expect("the grant keys an opener");
    let opened = opener.open(&datagram[TOKEN_SIZE..]).expect("the datagram authenticates");
    assert_eq!(opened.map(|frame| frame.kind), Some(MessageKind::VideoFrame));
}

#[test]
fn frames_go_on_the_control_connection_until_a_key_has_been_granted() {
    let mut lane = VideoLane::new(relay_token().0);
    let sends = lane.send(&VideoOutput::Frame(picture(1, 300)), 1.0).expect("a frame is encoded");
    assert!(matches!(sends.as_slice(), [LaneSend::ControlFrames(frames)] if frames.len() == 1));
}

#[test]
fn a_second_key_request_replaces_the_first_key() {
    let mut lane = VideoLane::new(relay_token().0);
    let first = lane.answer_key_request(&mut RepeatingBytes(0x01)).expect("first grant");
    let first_secret: VideoKeyGrant = serde_json::from_slice(&first.payload).expect("decodes");
    lane.answer_key_request(&mut RepeatingBytes(0x02)).expect("second grant");

    let sends = lane.send(&VideoOutput::Frame(picture(1, 64)), 1.0).expect("sealed");
    let LaneSend::Datagram(datagram) = &sends[0] else { panic!("expected a datagram") };
    let mut old = Opener::new(&first_secret.secret, Direction::HostToClient).expect("opener");
    assert!(old.open(&datagram[TOKEN_SIZE..]).is_err(), "the superseded key cannot open new video");
}

#[test]
fn a_fallback_request_is_declined_while_no_picture_has_been_produced() {
    let mut lane = VideoLane::new(relay_token().0);
    let answer = lane.handle_transport_request(
        &VideoTransportRequest { transport: VideoTransportKind::Control, reason: "silence".to_owned() },
        10.0,
    );
    assert_eq!(answer, HostAnswer::Decline);
    assert_eq!(lane.transport(), VideoTransportKind::Primary);
    assert_eq!(lane.bitrate_ceiling_kbps(), None);
}

#[test]
fn a_fallback_request_is_accepted_while_pictures_are_recent_and_capped_on_the_control_lane() {
    let mut lane = VideoLane::new(relay_token().0);
    lane.send(&VideoOutput::Frame(picture(1, 64)), 9.0).expect("sealed");

    let answer = lane.handle_transport_request(
        &VideoTransportRequest { transport: VideoTransportKind::Control, reason: "silence".to_owned() },
        10.0,
    );
    assert_eq!(answer, HostAnswer::Serve);
    assert_eq!(lane.transport(), VideoTransportKind::Control);
    assert_eq!(lane.bitrate_ceiling_kbps(), Some(2_000));

    let back = lane.handle_transport_request(
        &VideoTransportRequest { transport: VideoTransportKind::Primary, reason: "recovered".to_owned() },
        11.0,
    );
    assert_eq!(back, HostAnswer::Serve);
    assert_eq!(lane.bitrate_ceiling_kbps(), None);
}

#[test]
fn a_large_picture_on_the_control_lane_reassembles_on_the_client_in_order() {
    let mut lane = VideoLane::new(relay_token().0);
    lane.send(&VideoOutput::Frame(picture(1, 64)), 0.0).expect("a picture is produced");
    let answer = lane.handle_transport_request(
        &VideoTransportRequest { transport: VideoTransportKind::Control, reason: "silence".to_owned() },
        0.0,
    );
    assert_eq!(answer, HostAnswer::Serve);
    let mut client = Reassembler::new(MAX_REASSEMBLED);

    for sequence in [2u8, 3] {
        let frame = picture(sequence, 40_000);
        let expected = frame.encode().expect("encodes");
        let sends = lane.send(&VideoOutput::Frame(frame), 0.1).expect("sent");
        let [LaneSend::ControlFrames(pieces)] = sends.as_slice() else {
            panic!("expected control frames");
        };
        assert!(pieces.len() > 1, "a 40 kB picture is split across control frames");
        let (last, earlier) = pieces.split_last().expect("pieces");
        for piece in earlier {
            assert_eq!(client.ingest(piece).expect("chunk"), None);
        }
        let whole = client.ingest(last).expect("last chunk").expect("the picture is whole");
        assert_eq!(whole.kind, MessageKind::VideoFrame);
        assert_eq!(whole.payload, expected);
    }
}

#[test]
fn the_knocker_asks_the_relay_and_probes_quickly_then_slows_after_twelve_attempts() {
    let mut knocker = DirectPathKnocker::new();
    let peer: SocketAddr = "192.0.2.7:5000".parse().expect("address");
    knocker.on_peer_address(peer);
    assert_eq!(knocker.state(), DirectPathState::Probing);

    assert_eq!(knocker.due_probes(0.0), vec![ProbeAction::AskRelay, ProbeAction::SendProbe(peer)]);
    assert!(knocker.due_probes(0.2).is_empty());
    assert_eq!(knocker.due_probes(0.25), vec![ProbeAction::SendProbe(peer)]);
    let mut now = 0.25;
    for _ in 0..10 {
        now += 0.25;
        assert_eq!(knocker.due_probes(now), vec![ProbeAction::SendProbe(peer)]);
    }
    assert!(knocker.due_probes(now + 4.9).is_empty());
    assert_eq!(knocker.due_probes(now + 5.0), vec![ProbeAction::AskRelay, ProbeAction::SendProbe(peer)]);
}

#[test]
fn the_video_path_opens_only_once_a_probe_from_the_client_authenticates() {
    let mut knocker = DirectPathKnocker::new();
    let relayed: SocketAddr = "192.0.2.7:5000".parse().expect("address");
    let seen: SocketAddr = "198.51.100.9:6000".parse().expect("address");
    knocker.on_peer_address(relayed);
    assert_eq!(knocker.video_destination(), None);

    knocker.on_authenticated_datagram(seen);
    assert_eq!(knocker.state(), DirectPathState::Open);
    assert_eq!(knocker.video_destination(), Some(seen));
    assert_eq!(
        knocker.due_probes(100.0),
        vec![ProbeAction::AskRelay, ProbeAction::SendProbe(seen)],
        "the first call of a fresh knocker asks the relay and probes at once"
    );
}
