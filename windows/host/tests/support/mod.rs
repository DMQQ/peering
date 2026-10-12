//! The host runtime over fakes, and a scripted phone that talks to it over in-memory streams.
#![allow(dead_code)]

pub mod pairing;
pub use pairing::PairingClient;

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use peering_core::fakes::capture::FakeCapture;
use peering_core::fakes::clock::FakeClock;
use peering_core::fakes::encoder::FakeEncoder;
use peering_core::fakes::input::RecordingInput;
use peering_core::fakes::secret_store::InMemorySecretStore;
use peering_core::files::fake::InMemoryFileSystem;
use peering_core::ports::capture::{Capture, CaptureError, DisplayInfo, RawFrame};
use peering_core::ports::input::{InputSink, TransformSnapshot};
use peering_core::session::handshake::PROTOCOL_VERSION;
use peering_core::pairing::PairingOffer;
use peering_host::runtime::{HostProfile, HostRuntime, HostServices, PeerInfo};
use peering_wire::command::RemoteCommand;
use peering_wire::framing::{Frame, FrameDecoder, MessageKind};
use peering_wire::handshake::{ClientHello, PairConfirm, PairResult, ServerHello};
use peering_wire::source::{CaptureSource, NormalizedPoint};
use serde::de::DeserializeOwned;
use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream, ReadHalf, WriteHalf};
use tokio::task::{spawn_local, yield_now};

pub const CLIENT_ID: &str = "11111111-2222-3333-4444-555555555555";
pub const CLIENT_NAME: &str = "Pixel 9";
pub const HOST_ID: &str = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
pub const HOST_NAME: &str = "Studio PC";
pub const CLIENT_KEY: [u8; 65] = [0xC7; 65];
pub const HOST_KEY: [u8; 65] = [0xE5; 65];
const UNIX_NOW: u64 = 1_800_000_000;
const WAIT: Duration = Duration::from_secs(5);
pub const CONTROL_ROLE: u8 = 1;
pub const VIDEO_ROLE: u8 = 2;

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The capture the test controls. The runtime and the video coordinator both reach it through the wrapper.
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

/// The input the test inspects after the runtime has applied it.
pub struct SharedInput(pub Arc<Mutex<RecordingInput>>);

impl InputSink for SharedInput {
    fn apply(&mut self, command: &RemoteCommand, transform: &TransformSnapshot) {
        locked(&self.0).apply(command, transform);
    }

    fn release_all(&mut self) {
        locked(&self.0).release_all();
    }
}

pub struct Harness {
    pub runtime: HostRuntime,
    pub capture: Arc<Mutex<FakeCapture>>,
    pub input: Arc<Mutex<RecordingInput>>,
    pub secrets: Arc<InMemorySecretStore>,
    pub clock: Arc<FakeClock>,
}

pub fn display() -> DisplayInfo {
    DisplayInfo {
        id: 1,
        name: "Built-in".to_owned(),
        pixel_width: 3840,
        pixel_height: 2160,
        origin_x: 0,
        origin_y: 0,
        scale: 1.5,
        is_primary: true,
    }
}

pub fn harness() -> Harness {
    let capture = Arc::new(Mutex::new(FakeCapture::new(vec![display()])));
    let input = Arc::new(Mutex::new(RecordingInput::default()));
    let secrets = Arc::new(InMemorySecretStore::default());
    let mut files = InMemoryFileSystem::default();
    files.add_folder("C:\\Users\\me", 0.0);
    files.add_file("C:\\Users\\me\\notes.txt", b"hello", 0.0);
    let clock = Arc::new(FakeClock::new(100.0, UNIX_NOW));
    let services = HostServices {
        capture: Box::new(SharedCapture(capture.clone())),
        encoder: Box::new(FakeEncoder::default()),
        input: Box::new(SharedInput(input.clone())),
        secrets: secrets.clone(),
        files: Arc::new(files),
        home_directory: "C:\\Users\\me".to_owned(),
    };
    let profile = HostProfile {
        host_id: HOST_ID.to_owned(),
        host_name: HOST_NAME.to_owned(),
        identity_public_key: HOST_KEY.to_vec(),
        mac_addresses: Vec::new(),
        clock: clock.clone(),
    };
    let runtime = HostRuntime::new(profile, services).expect("the runtime builds over fakes");
    Harness { runtime, capture, input, secrets, clock }
}

pub fn direct_peer() -> PeerInfo {
    PeerInfo { public_key: Some(CLIENT_KEY.to_vec()), via_relay: false, video_token: None }
}

pub fn encode_json<T: Serialize>(kind: MessageKind, value: &T) -> Frame {
    Frame::new(kind, serde_json::to_vec(value).expect("test messages serialise"))
}

pub fn decode_json<T: DeserializeOwned>(frame: &Frame) -> T {
    serde_json::from_slice(&frame.payload).expect("the frame decodes")
}

pub fn role_frame(role: u8) -> Frame {
    Frame::new(MessageKind::ConnectionRole, vec![role])
}

/// One client end of a connection. The host serves the other end on the local task set.
pub struct Phone {
    reader: ReadHalf<DuplexStream>,
    writer: WriteHalf<DuplexStream>,
    decoder: FrameDecoder,
    queued: VecDeque<Frame>,
}

impl Phone {
    pub fn connect(runtime: &HostRuntime, peer: PeerInfo) -> Phone {
        let (client, host) = tokio::io::duplex(256 * 1024);
        let runtime = runtime.clone();
        spawn_local(async move { runtime.serve_stream(host, peer).await });
        let (reader, writer) = tokio::io::split(client);
        Phone { reader, writer, decoder: FrameDecoder::new(), queued: VecDeque::new() }
    }

    pub async fn send(&mut self, frame: Frame) {
        self.writer.write_all(&frame.encode()).await.expect("the host reads what the phone writes");
    }

    /// The next frame, or None once the host has closed the connection.
    pub async fn try_next(&mut self) -> Option<Frame> {
        let read_frames = async {
            loop {
                if let Some(frame) = self.queued.pop_front() {
                    return Some(frame);
                }
                let mut chunk = [0u8; 8192];
                let count = match self.reader.read(&mut chunk).await {
                    Ok(0) | Err(_) => return None,
                    Ok(count) => count,
                };
                self.decoder.push(&chunk[..count]);
                while let Some(frame) = self.decoder.next_frame().expect("the host writes valid frames") {
                    self.queued.push_back(frame);
                }
            }
        };
        tokio::time::timeout(WAIT, read_frames).await.expect("the host answers within five seconds")
    }

    pub async fn next(&mut self) -> Frame {
        self.try_next().await.expect("the host keeps the connection open")
    }

    /// The next frame of `kind`; frames of other kinds before it are skipped.
    pub async fn next_of(&mut self, kind: MessageKind) -> Frame {
        loop {
            let frame = self.next().await;
            if frame.kind == kind {
                return frame;
            }
        }
    }

    pub async fn send_json<T: Serialize>(&mut self, kind: MessageKind, value: &T) {
        self.send(encode_json(kind, value)).await;
    }

    pub async fn send_command(&mut self, command: &RemoteCommand) {
        self.send_json(MessageKind::Command, command).await;
    }

    /// Waits until the host has handled everything sent so far: a ping is answered after the frames before it.
    pub async fn sync(&mut self) {
        self.send(Frame::empty(MessageKind::Ping)).await;
        self.next_of(MessageKind::Pong).await;
    }
}

pub fn hello() -> Frame {
    let hello = ClientHello {
        client_id: CLIENT_ID.to_owned(),
        client_name: CLIENT_NAME.to_owned(),
        protocol_version: PROTOCOL_VERSION,
        wants_pairing: true,
        capabilities: Default::default(),
        resume_source: None,
        lost_pairing: None,
        client_platform: Some("android".to_owned()),
        video_codecs: None,
    };
    encode_json(MessageKind::ClientHello, &hello)
}

/// Polls `check` until it yields a value. Used where the host acts on its own task, so the test yields to let it run.
pub async fn until<T>(mut check: impl FnMut() -> Option<T>) -> T {
    for _ in 0..10_000 {
        if let Some(value) = check() {
            return value;
        }
        yield_now().await;
    }
    panic!("the host reached the expected state");
}

/// Lets the host process the reveal, then returns the pairing offer it shows.
pub async fn wait_for_offer(runtime: &HostRuntime) -> peering_core::pairing::PairingOffer {
    for _ in 0..10_000 {
        if let Some(offer) = runtime.pairing_offer() {
            return offer;
        }
        yield_now().await;
    }
    panic!("the host shows a pairing code");
}

/// Runs the handshake and the code exchange over `peer`, then confirms with the proof `proof_for` computes from the
/// offer. Returns the phone, the PairResult the host sent and the offer the host showed.
pub async fn pair_with_peer(
    runtime: &HostRuntime,
    peer: PeerInfo,
    proof_for: impl FnOnce(&PairingClient, &[u8]) -> Vec<u8>,
) -> (Phone, PairResult, PairingOffer) {
    let mut phone = Phone::connect(runtime, peer);
    let mut client = PairingClient::new();
    phone.send(role_frame(CONTROL_ROLE)).await;
    phone.send(hello()).await;
    phone.next_of(MessageKind::ServerHello).await;
    client.take_host_commit(&phone.next_of(MessageKind::PairCommit).await);
    phone.send(client.commit()).await;
    let reveal = phone.next_of(MessageKind::PairReveal).await;
    assert!(client.take_host_reveal(&reveal), "the host reveal matches its commitment");
    phone.send(client.reveal()).await;
    let offer = wait_for_offer(runtime).await;
    assert_eq!(client.code(), offer.code, "both ends compute the same six digits");
    let secret = hex::decode(&offer.secret_hex).expect("the offer carries hex");
    let proof = proof_for(&client, &secret);
    phone.send_json(MessageKind::PairConfirm, &PairConfirm { accepted: true, proof: Some(proof) }).await;
    let result: PairResult = decode_json(&phone.next_of(MessageKind::PairResult).await);
    (phone, result, offer)
}

/// Pairs over a direct connection with the proof computed from the QR secret, and returns the phone authorised.
pub async fn paired_phone(runtime: &HostRuntime) -> Phone {
    let (phone, result, _offer) = pair_with_peer(runtime, direct_peer(), |client, secret| client.proof(secret)).await;
    assert!(result.accepted, "the pairing is accepted");
    phone
}

pub fn server_hello(frame: &Frame) -> ServerHello {
    decode_json(frame)
}

pub fn select_display_command() -> RemoteCommand {
    RemoteCommand::SetCaptureSource { source: CaptureSource::Display { id: 1 } }
}

pub fn mouse_move(x: f64, y: f64) -> RemoteCommand {
    RemoteCommand::MouseMove { to: NormalizedPoint { x, y } }
}

/// Runs a test body on a current-thread runtime with a local task set, as the host does.
pub fn run<F: std::future::Future<Output = ()>>(body: F) {
    let executor = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("an executor starts");
    tokio::task::LocalSet::new().block_on(&executor, body);
}
