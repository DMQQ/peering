//! Helpers shared by the peering-core flow tests. Each test binary uses a different subset, hence the allow.
#![allow(dead_code)]

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use peering_core::fakes::clock::FakeClock;
use peering_core::fakes::capture::FakeCapture;
use peering_core::fakes::encoder::FakeEncoder;
use peering_core::fakes::input::RecordingInput;
use peering_core::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame};
use peering_core::ports::encoder::{EncodeError, EncodedOutput, Encoder};
use peering_core::video::coordinator::VideoCoordinator;
use peering_wire::source::CaptureSource;
use peering_wire::video::VideoStreamConfig;
use peering_core::ports::input::TransformSnapshot;
use peering_core::session::dispatch::{DispatchContext, SourceControl};
use peering_core::ports::clock::Clock;
use peering_core::session::actions::{CloseReason, SessionAction};
use peering_core::session::deps::{HostDeps, PairedDevice, PinStore, Random};
use peering_core::session::handshake::{HostConfig, HostSession};
use peering_wire::framing::{Frame, MessageKind};
use peering_wire::handshake::{ClientHello, PairConfirm, PairResult, PairingCommit, PairingReveal};
use peering_wire::sas::{self, PairingTranscript};
use serde::de::DeserializeOwned;
use serde::Serialize;

pub const CLIENT_ID: &str = "11111111-2222-3333-4444-555555555555";
pub const CLIENT_NAME: &str = "Pixel 9";
pub const HOST_ID: &str = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
pub const HOST_NAME: &str = "Studio PC";
pub const CLIENT_KEY: [u8; 65] = [0xC7; 65];
pub const HOST_KEY: [u8; 65] = [0xE5; 65];
pub const CLIENT_EPHEMERAL: [u8; 65] = [0xA1; 65];
pub const HOST_EPHEMERAL: [u8; 65] = [0xB2; 65];
pub const CLIENT_NONCE: [u8; 32] = [0xC3; 32];
pub const HOST_NONCE: [u8; 32] = [0xD4; 32];
pub const SECRET: [u8; 16] = [0x5E; 16];
pub const UNIX_NOW: u64 = 1_800_000_000;
pub const MAC_ADDRESS: &str = "aa:bb:cc:dd:ee:ff";

/// Hands the host the same values every time, so a test can check the host's commitment against them.
pub struct FixedRandom;

impl Random for FixedRandom {
    fn ephemeral_public_key(&mut self) -> Vec<u8> {
        HOST_EPHEMERAL.to_vec()
    }

    fn nonce(&mut self) -> Vec<u8> {
        HOST_NONCE.to_vec()
    }

    fn secret(&mut self) -> Vec<u8> {
        SECRET.to_vec()
    }
}

/// A pin store kept in a map. `set_fail_writes(true)` makes `record` report failure and store nothing.
#[derive(Default)]
pub struct MemoryPins {
    devices: Mutex<HashMap<String, PairedDevice>>,
    fail_writes: AtomicBool,
}

impl MemoryPins {
    pub fn with_device(device: PairedDevice) -> Self {
        let pins = Self::default();
        locked(&pins.devices).insert(device.id.clone(), device);
        pins
    }

    pub fn set_fail_writes(&self, fail: bool) {
        self.fail_writes.store(fail, Ordering::SeqCst);
    }
}

impl PinStore for MemoryPins {
    fn pin_for(&self, client_id: &str) -> Option<Vec<u8>> {
        locked(&self.devices).get(client_id).map(|device| device.public_key.clone())
    }

    fn record(&self, device: &PairedDevice) -> bool {
        if self.fail_writes.load(Ordering::SeqCst) {
            return false;
        }
        locked(&self.devices).insert(device.id.clone(), device.clone());
        true
    }

    fn mark_seen(&self, client_id: &str, unix_seconds: u64) {
        if let Some(device) = locked(&self.devices).get_mut(client_id) {
            device.last_seen_unix = unix_seconds;
        }
    }

    fn devices(&self) -> Vec<PairedDevice> {
        let mut devices: Vec<PairedDevice> = locked(&self.devices).values().cloned().collect();
        devices.sort_by(|a, b| a.id.cmp(&b.id));
        devices
    }

    fn revoke(&self, client_id: &str) -> bool {
        locked(&self.devices).remove(client_id).is_some()
    }
}

pub fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

pub fn paired_device(public_key: &[u8]) -> PairedDevice {
    PairedDevice {
        id: CLIENT_ID.to_owned(),
        name: CLIENT_NAME.to_owned(),
        public_key: public_key.to_vec(),
        last_seen_unix: 1,
    }
}

pub fn host_config(peer_public_key: Option<Vec<u8>>) -> HostConfig {
    HostConfig {
        host_id: HOST_ID.to_owned(),
        host_name: HOST_NAME.to_owned(),
        identity_public_key: HOST_KEY.to_vec(),
        mac_addresses: vec![MAC_ADDRESS.to_owned()],
        peer_public_key,
        arrived_through_relay: false,
    }
}

pub fn clock_at(monotonic_seconds: f64) -> Arc<FakeClock> {
    Arc::new(FakeClock::new(monotonic_seconds, UNIX_NOW))
}

/// A host session whose clock is the one passed in, so a test can advance it.
pub fn host_session(pins: Arc<dyn PinStore>, peer_public_key: Option<Vec<u8>>, clock: Arc<dyn Clock>) -> HostSession {
    HostSession::new(
        host_config(peer_public_key),
        HostDeps { random: Box::new(FixedRandom), pins, clock },
    )
}

pub fn role_frame(role: u8) -> Frame {
    Frame::new(MessageKind::ConnectionRole, vec![role])
}

pub const CONTROL_ROLE: u8 = 1;
pub const VIDEO_ROLE: u8 = 2;

pub fn encode_json<T: Serialize>(kind: MessageKind, value: &T) -> Frame {
    Frame::new(kind, serde_json::to_vec(value).expect("test message serialises"))
}

pub fn decode_json<T: DeserializeOwned>(frame: &Frame) -> T {
    serde_json::from_slice(&frame.payload).expect("frame decodes")
}

pub fn sent_frames(actions: &[SessionAction]) -> Vec<Frame> {
    actions
        .iter()
        .filter_map(|action| match action {
            SessionAction::Send(frame) => Some(frame.clone()),
            _ => None,
        })
        .collect()
}

/// The first frame of `kind` the session sent in these actions.
pub fn sent_of(actions: &[SessionAction], kind: MessageKind) -> Option<Frame> {
    sent_frames(actions).into_iter().find(|frame| frame.kind == kind)
}

pub fn close_reason(actions: &[SessionAction]) -> Option<CloseReason> {
    actions.iter().find_map(|action| match action {
        SessionAction::Close(reason) => Some(reason.clone()),
        _ => None,
    })
}

pub fn has_authorised(actions: &[SessionAction]) -> bool {
    actions.contains(&SessionAction::Authorized)
}

pub fn pair_result_of(actions: &[SessionAction]) -> PairResult {
    let frame = sent_of(actions, MessageKind::PairResult).expect("a pairResult frame");
    decode_json(&frame)
}

/// The six digit code and the secret the Mac shows, from the event the session emits.
pub fn pairing_code_of(actions: &[SessionAction]) -> Option<(String, Vec<u8>)> {
    actions.iter().find_map(|action| match action {
        SessionAction::Emit(peering_core::session::actions::HostEvent::PairingCode { code, secret, .. }) => {
            Some((code.clone(), secret.clone()))
        }
        _ => None,
    })
}

/// A phone that pairs with the host, computing the code from the values it actually received.
pub struct PairingClient {
    pub id: String,
    pub name: String,
    pub public_key: Vec<u8>,
    ephemeral: Vec<u8>,
    nonce: Vec<u8>,
    host_commitment: Option<Vec<u8>>,
    host_ephemeral: Option<Vec<u8>>,
    host_nonce: Option<Vec<u8>>,
}

impl PairingClient {
    pub fn new() -> Self {
        Self {
            id: CLIENT_ID.to_owned(),
            name: CLIENT_NAME.to_owned(),
            public_key: CLIENT_KEY.to_vec(),
            ephemeral: CLIENT_EPHEMERAL.to_vec(),
            nonce: CLIENT_NONCE.to_vec(),
            host_commitment: None,
            host_ephemeral: None,
            host_nonce: None,
        }
    }

    pub fn hello(&self) -> Frame {
        self.hello_with(|hello| hello)
    }

    /// A hello built from the defaults, with one field changed by the closure.
    pub fn hello_with(&self, edit: impl FnOnce(ClientHello) -> ClientHello) -> Frame {
        let hello = ClientHello {
            client_id: self.id.clone(),
            client_name: self.name.clone(),
            protocol_version: peering_core::session::handshake::PROTOCOL_VERSION,
            wants_pairing: true,
            capabilities: Default::default(),
            resume_source: None,
            lost_pairing: None,
            client_platform: Some("android".to_owned()),
            video_codecs: None,
        };
        encode_json(MessageKind::ClientHello, &edit(hello))
    }

    pub fn commit(&self) -> Frame {
        let commitment = sas::commitment(&self.ephemeral, &self.nonce).to_vec();
        encode_json(MessageKind::PairCommit, &PairingCommit { commitment })
    }

    /// Records the host's commitment, so its reveal can be checked against it.
    pub fn take_host_commit(&mut self, frame: &Frame) {
        let commit: PairingCommit = decode_json(frame);
        self.host_commitment = Some(commit.commitment);
    }

    pub fn reveal(&self) -> Frame {
        encode_json(
            MessageKind::PairReveal,
            &PairingReveal { ephemeral_public_key: self.ephemeral.clone(), nonce: self.nonce.clone() },
        )
    }

    /// Checks the host's reveal against its commitment and keeps the host's values for the code.
    pub fn take_host_reveal(&mut self, frame: &Frame) -> bool {
        let reveal: PairingReveal = decode_json(frame);
        let Some(commitment) = self.host_commitment.as_deref() else {
            return false;
        };
        if !sas::verify_commitment(commitment, &reveal.ephemeral_public_key, &reveal.nonce) {
            return false;
        }
        self.host_ephemeral = Some(reveal.ephemeral_public_key);
        self.host_nonce = Some(reveal.nonce);
        true
    }

    /// The six digit code this phone computes. It must equal the one the Mac shows.
    pub fn code(&self) -> String {
        self.transcript().code()
    }

    pub fn proof(&self, secret: &[u8]) -> Vec<u8> {
        self.transcript().proof(secret)
    }

    pub fn confirm(&self, accepted: bool, proof: Option<Vec<u8>>) -> Frame {
        encode_json(MessageKind::PairConfirm, &PairConfirm { accepted, proof })
    }

    fn transcript(&self) -> PairingTranscript {
        PairingTranscript {
            protocol_version: peering_core::session::handshake::PROTOCOL_VERSION,
            client_id: self.id.clone(),
            server_id: HOST_ID.to_owned(),
            client_ephemeral_public_key: self.ephemeral.clone(),
            server_ephemeral_public_key: self.host_ephemeral.clone().expect("the host reveal was taken"),
            client_nonce: self.nonce.clone(),
            server_nonce: self.host_nonce.clone().expect("the host reveal was taken"),
            server_identity_public_key: HOST_KEY.to_vec(),
        }
    }
}

/// Runs the control role and hello, then the commit and reveal exchange, and returns the phone's view of the code.
/// `session` must be unpaired and the phone unknown to it.
pub fn pair_up_to_code(session: &mut HostSession, phone: &mut PairingClient) -> (String, Vec<u8>) {
    session.on_frame(role_frame(CONTROL_ROLE));
    let hello_actions = session.on_frame(phone.hello());
    phone.take_host_commit(&sent_of(&hello_actions, MessageKind::PairCommit).expect("host commits first"));
    let host_reveal = session.on_frame(phone.commit());
    let reveal = sent_of(&host_reveal, MessageKind::PairReveal).expect("host reveals after the client commits");
    assert!(phone.take_host_reveal(&reveal), "the host reveal matches its commitment");
    let code_actions = session.on_frame(phone.reveal());
    let (code, secret) = pairing_code_of(&code_actions).expect("the Mac shows a code");
    assert_eq!(phone.code(), code, "both ends compute the same six digits");
    (code, secret)
}

/// Records what the dispatcher asked of the capture and encoder, in order.
#[derive(Debug, Default)]
pub struct RecordingSource {
    pub sources: Vec<peering_wire::source::CaptureSource>,
    pub qualities: Vec<(Option<u32>, Option<u32>)>,
    pub video_enabled: Vec<bool>,
    pub locks: usize,
}

impl SourceControl for RecordingSource {
    fn set_source(&mut self, source: peering_wire::source::CaptureSource) {
        self.sources.push(source);
    }

    fn set_quality(&mut self, fps: Option<u32>, bitrate_kbps: Option<u32>) {
        self.qualities.push((fps, bitrate_kbps));
    }

    fn set_video_enabled(&mut self, enabled: bool) {
        self.video_enabled.push(enabled);
    }

    fn lock_screen(&mut self) {
        self.locks += 1;
    }
}

/// The dispatch context a ready session is given, with the transform the caller computed for its active display.
pub fn dispatch_context<'a>(
    input: &'a mut RecordingInput,
    source: &'a mut dyn SourceControl,
    observe_mode: bool,
) -> DispatchContext<'a> {
    DispatchContext {
        observe_mode,
        transform: TransformSnapshot { origin_x: 0, origin_y: 0, pixel_width: 1512, pixel_height: 982, scale: 2.0 },
        input,
        source,
    }
}

pub const RELAY_TOKEN_HEX: &str = "00112233445566778899aabbccddeeff";

pub fn relay_token() -> peering_wire::relay_messages::Token {
    peering_wire::relay_messages::Token::parse(RELAY_TOKEN_HEX).expect("a 32 digit token")
}

/// A picture whose first one is a keyframe, carrying `size` bytes of data.
pub fn picture(sequence: u8, size: usize) -> peering_wire::video::EncodedVideoFrame {
    peering_wire::video::EncodedVideoFrame {
        is_keyframe: sequence == 1,
        pixel_width: 1920,
        pixel_height: 1080,
        presentation_time: peering_wire::video::VideoTimestamp { value: i64::from(sequence), timescale: 60 },
        data: vec![sequence; size],
    }
}

/// Shares a capture between a test and the coordinator that owns it, so the test can push frames.
#[derive(Clone)]
pub struct SharedCapture(pub Arc<Mutex<FakeCapture>>);

impl Capture for SharedCapture {
    fn list_displays(&self) -> Vec<DisplayInfo> {
        locked(&self.0).list_displays()
    }

    fn start(&mut self, display_id: u32) -> Result<(), CaptureError> {
        locked(&self.0).start(display_id)
    }

    fn stop(&mut self) {
        locked(&self.0).stop();
    }

    fn poll_frame(&mut self) -> Option<RawFrame> {
        locked(&self.0).poll_frame()
    }
}

/// Shares an encoder between a test and the coordinator that owns it, so the test can read the calls made.
#[derive(Clone)]
pub struct SharedEncoder(pub Arc<Mutex<FakeEncoder>>);

impl Encoder for SharedEncoder {
    fn configure(&mut self, width: u32, height: u32, fps: u32, bitrate_bps: u32) -> Result<(), EncodeError> {
        locked(&self.0).configure(width, height, fps, bitrate_bps)
    }

    fn encode(&mut self, frame: &RawFrame, force_keyframe: bool) -> Result<Vec<EncodedOutput>, EncodeError> {
        locked(&self.0).encode(frame, force_keyframe)
    }

    fn set_bitrate(&mut self, bitrate_bps: u32) {
        locked(&self.0).set_bitrate(bitrate_bps);
    }
}

pub type TestCoordinator = VideoCoordinator<SharedCapture, SharedEncoder>;

/// A coordinator over shared fakes, with the displays given. The returned handles are the test's view of the fakes.
pub type CaptureHandle = Arc<Mutex<FakeCapture>>;
pub type EncoderHandle = Arc<Mutex<FakeEncoder>>;

pub fn shared_coordinator(displays: Vec<DisplayInfo>) -> (TestCoordinator, CaptureHandle, EncoderHandle) {
    let capture = Arc::new(Mutex::new(FakeCapture::new(displays)));
    let encoder = Arc::new(Mutex::new(FakeEncoder::default()));
    let coordinator = VideoCoordinator::new(SharedCapture(capture.clone()), SharedEncoder(encoder.clone()));
    (coordinator, capture, encoder)
}

pub fn display_info(id: u32, is_primary: bool) -> DisplayInfo {
    DisplayInfo {
        id,
        name: format!("Display {id}"),
        pixel_width: 1512,
        pixel_height: 982,
        origin_x: if is_primary { 0 } else { 1512 },
        origin_y: 0,
        scale: 2.0,
        is_primary,
    }
}

pub fn raw_frame(sequence: u64) -> RawFrame {
    RawFrame { width: 1512, height: 982, sequence }
}

/// The control source the dispatcher forwards to, backed by a coordinator. Errors the coordinator reports are kept
/// in `rejected`, since the dispatcher has no way to return them.
pub struct CoordinatorControl {
    pub coordinator: TestCoordinator,
    pub now: f64,
    pub rejected: Vec<String>,
}

impl SourceControl for CoordinatorControl {
    fn set_source(&mut self, source: CaptureSource) {
        if let Err(error) = self.coordinator.set_source(source, self.now) {
            self.rejected.push(error.to_string());
        }
    }

    fn set_quality(&mut self, _fps: Option<u32>, bitrate_kbps: Option<u32>) {
        if let Some(kbps) = bitrate_kbps {
            self.coordinator.set_quality(i64::from(kbps));
        }
    }

    fn set_video_enabled(&mut self, enabled: bool) {
        self.coordinator.set_video_enabled(enabled);
    }

    fn lock_screen(&mut self) {}
}

pub fn config_of(outputs: &[peering_core::video::coordinator::VideoOutput]) -> Option<VideoStreamConfig> {
    outputs.iter().find_map(|output| match output {
        peering_core::video::coordinator::VideoOutput::Config(config) => Some(config.clone()),
        _ => None,
    })
}

pub fn keyframe_of(outputs: &[peering_core::video::coordinator::VideoOutput]) -> Option<bool> {
    outputs.iter().find_map(|output| match output {
        peering_core::video::coordinator::VideoOutput::Frame(frame) => Some(frame.is_keyframe),
        _ => None,
    })
}
