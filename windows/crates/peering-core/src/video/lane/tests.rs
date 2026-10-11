use super::*;
use peering_wire::chunks::{Reassembler, CONTROL_CHUNK_SIZE, HEADER_SIZE};
use peering_wire::sealing::{Opener, Sealer, MAX_DATAGRAM_SIZE};
use peering_wire::video::{EncodedVideoFrame, VideoCodec, VideoStreamConfig, VideoTimestamp};

const TOKEN: [u8; TOKEN_SIZE] = [7; TOKEN_SIZE];
const SECRET_BYTE: u8 = 0x11;

struct FixedRandom(u8);

impl Random for FixedRandom {
    fn fill(&mut self, buffer: &mut [u8]) {
        buffer.fill(self.0);
    }
}

fn keyed_lane() -> VideoLane {
    let mut lane = VideoLane::new(TOKEN);
    lane.answer_key_request(&mut FixedRandom(SECRET_BYTE)).unwrap();
    lane
}

fn client_opener() -> Opener {
    Opener::new(&[SECRET_BYTE; SECRET_SIZE], Direction::HostToClient).unwrap()
}

fn video(is_keyframe: bool, size: usize) -> VideoOutput {
    VideoOutput::Frame(EncodedVideoFrame {
        is_keyframe,
        pixel_width: 1920,
        pixel_height: 1080,
        presentation_time: VideoTimestamp { value: 1, timescale: 60 },
        data: vec![0xAB; size],
    })
}

fn request(transport: VideoTransportKind) -> VideoTransportRequest {
    VideoTransportRequest { transport, reason: "test".to_owned() }
}

fn datagrams(sends: &[LaneSend]) -> Vec<Vec<u8>> {
    sends
        .iter()
        .filter_map(|send| match send {
            LaneSend::Datagram(bytes) => Some(bytes.clone()),
            LaneSend::ControlFrames(_) => None,
        })
        .collect()
}

fn control_pieces(sends: &[LaneSend]) -> Vec<Frame> {
    sends
        .iter()
        .flat_map(|send| match send {
            LaneSend::ControlFrames(frames) => frames.clone(),
            LaneSend::Datagram(_) => Vec::new(),
        })
        .collect()
}

/// What the relay forwards to the client: the token is removed before the datagram arrives.
fn forwarded(datagram: &[u8]) -> &[u8] {
    &datagram[TOKEN_SIZE..]
}

fn open_all(opener: &mut Opener, sends: &[LaneSend]) -> Vec<Frame> {
    datagrams(sends)
        .iter()
        .filter_map(|datagram| opener.open(forwarded(datagram)).unwrap())
        .collect()
}

#[test]
fn a_key_request_is_answered_with_a_video_key_carrying_the_secret() {
    let mut lane = VideoLane::new(TOKEN);
    let grant = lane.answer_key_request(&mut FixedRandom(SECRET_BYTE)).unwrap();
    assert_eq!(grant.kind, MessageKind::VideoKey);
    let parsed: VideoKeyGrant = serde_json::from_slice(&grant.payload).unwrap();
    assert_eq!(parsed.secret, vec![SECRET_BYTE; SECRET_SIZE]);
}

#[test]
fn datagrams_open_with_the_client_side_opener_in_order() {
    let mut lane = keyed_lane();
    let config = VideoOutput::Config(VideoStreamConfig {
        source_id: "display:1".to_owned(),
        codec: VideoCodec::H264,
        pixel_width: 1920,
        pixel_height: 1080,
        parameter_sets: vec![vec![0x67, 0x42]],
    });
    let big = video(true, 5_000);
    let mut sends = lane.send(&config, 1.0).unwrap();
    sends.extend(lane.send(&big, 1.0).unwrap());
    let mut opener = client_opener();
    let opened = open_all(&mut opener, &sends);
    assert_eq!(opened.len(), 2);
    assert_eq!(opened[0].kind, MessageKind::VideoConfig);
    assert_eq!(opened[1].kind, MessageKind::VideoFrame);
    let VideoOutput::Frame(frame) = &big else { unreachable!() };
    assert_eq!(opened[1].payload, frame.encode().unwrap());
}

#[test]
fn every_sealed_datagram_fits_the_protocol_limit_and_starts_with_the_token() {
    let mut lane = keyed_lane();
    let sends = lane.send(&video(true, 20_000), 1.0).unwrap();
    let sent = datagrams(&sends);
    assert!(sent.len() > 1);
    for datagram in sent {
        assert!(datagram.len() <= MAX_DATAGRAM_SIZE);
        assert_eq!(&datagram[..TOKEN_SIZE], &TOKEN);
    }
}

#[test]
fn video_before_a_key_goes_unsealed_on_the_control_lane() {
    let mut lane = VideoLane::new(TOKEN);
    let sends = lane.send(&video(true, 100), 1.0).unwrap();
    let pieces = control_pieces(&sends);
    assert_eq!(pieces.len(), 1);
    assert_eq!(pieces[0].kind, MessageKind::VideoFrame);
}

#[test]
fn a_second_key_request_replaces_the_first_key() {
    let mut lane = keyed_lane();
    lane.answer_key_request(&mut FixedRandom(0x22)).unwrap();
    let sends = lane.send(&video(true, 100), 1.0).unwrap();
    let mut old_opener = client_opener();
    let first = datagrams(&sends)[0].clone();
    assert_eq!(old_opener.open(forwarded(&first)), Err(SealError::AuthenticationFailed));
}

#[test]
fn control_is_declined_while_nothing_has_been_produced() {
    let mut lane = keyed_lane();
    assert_eq!(lane.handle_transport_request(&request(VideoTransportKind::Control), 10.0), HostAnswer::Decline);
    assert_eq!(lane.transport(), VideoTransportKind::Primary);
    assert_eq!(lane.bitrate_ceiling_kbps(), None);
}

#[test]
fn control_is_granted_when_a_frame_was_produced_within_the_window() {
    let mut lane = keyed_lane();
    lane.send(&video(false, 100), 10.0).unwrap();
    assert_eq!(lane.handle_transport_request(&request(VideoTransportKind::Control), 10.5), HostAnswer::Serve);
    assert_eq!(lane.transport(), VideoTransportKind::Control);
    assert_eq!(lane.bitrate_ceiling_kbps(), Some(CONTROL_LANE_CAP_KBPS));
}

#[test]
fn control_is_declined_when_the_last_frame_is_older_than_the_window() {
    let mut lane = keyed_lane();
    lane.send(&video(false, 100), 10.0).unwrap();
    assert_eq!(lane.handle_transport_request(&request(VideoTransportKind::Control), 15.5), HostAnswer::Decline);
    assert_eq!(lane.transport(), VideoTransportKind::Primary);
}

#[test]
fn a_request_for_the_primary_lane_returns_to_datagrams_and_lifts_the_cap() {
    let mut lane = keyed_lane();
    lane.send(&video(false, 100), 10.0).unwrap();
    lane.handle_transport_request(&request(VideoTransportKind::Control), 10.0);
    assert_eq!(lane.handle_transport_request(&request(VideoTransportKind::Primary), 11.0), HostAnswer::Serve);
    assert_eq!(lane.transport(), VideoTransportKind::Primary);
    assert_eq!(lane.bitrate_ceiling_kbps(), None);
}

#[test]
fn a_large_picture_on_the_control_lane_is_chunked_and_reassembles() {
    let mut lane = keyed_lane();
    lane.send(&video(false, 100), 10.0).unwrap();
    lane.handle_transport_request(&request(VideoTransportKind::Control), 10.0);
    let picture = video(false, 40_000);
    let sends = lane.send(&picture, 10.1).unwrap();
    let pieces = control_pieces(&sends);
    assert!(pieces.len() > 1);
    let mut reassembler = Reassembler::default();
    let mut assembled = None;
    for piece in &pieces {
        assert!(piece.payload.len() <= HEADER_SIZE + CONTROL_CHUNK_SIZE);
        assembled = reassembler.ingest(piece).unwrap().or(assembled);
    }
    let VideoOutput::Frame(frame) = &picture else { unreachable!() };
    assert_eq!(assembled, Some(Frame::new(MessageKind::VideoFrame, frame.encode().unwrap())));
}

#[test]
fn a_keyframe_on_the_control_lane_is_also_sent_on_the_primary_lane_every_four_seconds() {
    let mut lane = keyed_lane();
    lane.send(&video(false, 100), 10.0).unwrap();
    lane.handle_transport_request(&request(VideoTransportKind::Control), 10.0);
    let first = lane.send(&video(true, 100), 10.6).unwrap();
    assert!(!datagrams(&first).is_empty());
    assert!(!control_pieces(&first).is_empty());
    let within = lane.send(&video(true, 100), 12.0).unwrap();
    assert!(datagrams(&within).is_empty());
    let due = lane.send(&video(true, 100), 14.7).unwrap();
    assert!(!datagrams(&due).is_empty());
}

#[test]
fn a_delta_frame_on_the_control_lane_is_not_probed_on_the_primary_lane() {
    let mut lane = keyed_lane();
    lane.send(&video(false, 100), 10.0).unwrap();
    lane.handle_transport_request(&request(VideoTransportKind::Control), 10.0);
    let sends = lane.send(&video(false, 100), 15.0).unwrap();
    assert!(datagrams(&sends).is_empty());
}

#[test]
fn the_client_probe_opens_with_the_client_key_and_a_replay_is_refused() {
    let mut lane = keyed_lane();
    let mut client = Sealer::new(&[SECRET_BYTE; SECRET_SIZE], Direction::ClientToHost, TOKEN).unwrap();
    let probe = client.seal(MessageKind::DirectProbe, &[]).remove(0);
    let opened = lane.open_from_client(forwarded(&probe)).unwrap();
    assert_eq!(opened, Some(Frame::empty(MessageKind::DirectProbe)));
    assert_eq!(lane.open_from_client(forwarded(&probe)).unwrap(), None);
}

#[test]
fn client_datagrams_are_ignored_before_a_key_exists() {
    let mut lane = VideoLane::new(TOKEN);
    let mut client = Sealer::new(&[SECRET_BYTE; SECRET_SIZE], Direction::ClientToHost, TOKEN).unwrap();
    let probe = client.seal(MessageKind::DirectProbe, &[]).remove(0);
    assert_eq!(lane.open_from_client(forwarded(&probe)).unwrap(), None);
}

#[test]
fn the_bind_is_sent_at_once_and_then_every_ten_seconds() {
    let mut lane = VideoLane::new(TOKEN);
    assert_eq!(lane.bind_if_due(0.0), Some(TOKEN.to_vec()));
    assert_eq!(lane.bind_if_due(9.9), None);
    assert_eq!(lane.bind_if_due(10.0), Some(TOKEN.to_vec()));
}
