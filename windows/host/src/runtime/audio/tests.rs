use std::sync::Arc;

use peering_core::fakes::audio::ScriptedAudio;
use peering_core::ports::audio::CapturedAudio;
use peering_wire::framing::MessageKind;
use peering_wire::video::EncodedAudioFrame;

use super::super::services::platform_services;
use super::super::shared::SessionSlot;
use super::super::test_support::slot;
use super::super::video::Outgoing;
use super::super::{HostProfile, HostRuntime, SystemClock};

fn runtime_with(audio: &ScriptedAudio) -> HostRuntime {
    let mut services = platform_services(String::new()).expect("the stand-in adapters build");
    services.extras.audio = Box::new(audio.clone());
    let profile = HostProfile {
        host_id: "host".to_owned(),
        host_name: "PC".to_owned(),
        identity_public_key: Vec::new(),
        mac_addresses: Vec::new(),
        clock: Arc::new(SystemClock::new()),
    };
    HostRuntime::new(profile, services).expect("the runtime builds")
}

fn frames_of_sound(frames: usize) -> CapturedAudio {
    CapturedAudio { sample_rate: 48_000, channels: 2, samples: vec![0.25; 960 * 2 * frames] }
}

fn kinds(outgoing: &[Outgoing]) -> Vec<MessageKind> {
    outgoing.iter().map(|item| item.frame.kind).collect()
}

#[test]
fn nothing_is_listened_to_while_no_phone_is_connected() {
    let audio = ScriptedAudio::default();
    let runtime = runtime_with(&audio);
    audio.feed(frames_of_sound(1));
    assert!(runtime.shared.lock().pump_audio().is_empty());
    assert!(!audio.is_active());
}

#[test]
fn a_connected_phone_starts_listening_and_the_last_one_leaving_stops_it() {
    let audio = ScriptedAudio::default();
    let runtime = runtime_with(&audio);
    runtime.shared.lock().sessions.insert(1, slot("phone"));
    runtime.shared.lock().pump_audio();
    assert!(audio.is_active());
    runtime.shared.lock().sessions.clear();
    runtime.shared.lock().pump_audio();
    assert_eq!(audio.activations(), vec![true, false]);
}

#[test]
fn a_phone_in_the_background_is_not_listened_for() {
    let audio = ScriptedAudio::default();
    let runtime = runtime_with(&audio);
    runtime.shared.lock().sessions.insert(1, SessionSlot { background: true, ..slot("phone") });
    audio.feed(frames_of_sound(1));
    assert!(runtime.shared.lock().pump_audio().is_empty());
    assert!(!audio.is_active());
}

#[test]
fn the_config_comes_once_and_then_frames_of_960_samples() {
    let audio = ScriptedAudio::default();
    let runtime = runtime_with(&audio);
    runtime.shared.lock().sessions.insert(1, slot("phone"));
    runtime.shared.lock().pump_audio();
    audio.feed(frames_of_sound(2));
    let first = runtime.shared.lock().pump_audio();
    assert_eq!(kinds(&first), vec![MessageKind::AudioConfig, MessageKind::AudioFrame, MessageKind::AudioFrame]);
    let decoded = EncodedAudioFrame::decode(&first[1].frame.payload).expect("a valid frame");
    assert_eq!((decoded.sample_count, decoded.channel_count), (960, 2));

    audio.feed(frames_of_sound(1));
    assert_eq!(kinds(&runtime.shared.lock().pump_audio()), vec![MessageKind::AudioFrame], "no second config");
}

#[test]
fn a_phone_that_returns_from_the_background_is_sent_the_config_again() {
    let audio = ScriptedAudio::default();
    let runtime = runtime_with(&audio);
    runtime.shared.lock().sessions.insert(1, slot("phone"));
    runtime.shared.lock().pump_audio();
    audio.feed(frames_of_sound(1));
    runtime.shared.lock().pump_audio();

    runtime.shared.lock().sessions.get_mut(&1).expect("the session").background = true;
    runtime.shared.lock().pump_audio();
    runtime.shared.lock().sessions.get_mut(&1).expect("the session").background = false;
    runtime.shared.lock().pump_audio();
    audio.feed(frames_of_sound(1));
    assert_eq!(kinds(&runtime.shared.lock().pump_audio())[0], MessageKind::AudioConfig);
}

#[test]
fn every_foreground_phone_gets_the_sound_and_a_background_one_does_not() {
    let audio = ScriptedAudio::default();
    let runtime = runtime_with(&audio);
    runtime.shared.lock().sessions.insert(1, slot("one"));
    runtime.shared.lock().sessions.insert(2, slot("two"));
    runtime.shared.lock().sessions.insert(3, SessionSlot { background: true, ..slot("three") });
    runtime.shared.lock().pump_audio();
    audio.feed(frames_of_sound(1));
    let outgoing = runtime.shared.lock().pump_audio();
    assert_eq!(outgoing.len(), 4, "a config and a frame for each of two phones");
}

#[test]
fn the_tail_of_a_sound_is_sent_once_the_pc_goes_quiet() {
    let audio = ScriptedAudio::default();
    let runtime = runtime_with(&audio);
    runtime.shared.lock().sessions.insert(1, slot("phone"));
    runtime.shared.lock().pump_audio();
    audio.feed(CapturedAudio { sample_rate: 48_000, channels: 2, samples: vec![0.5; 100 * 2] });
    assert!(runtime.shared.lock().pump_audio().is_empty(), "less than a frame is held back");
    assert!(runtime.shared.lock().pump_audio().is_empty());
    assert!(runtime.shared.lock().pump_audio().is_empty());
    let tail = runtime.shared.lock().pump_audio();
    assert_eq!(kinds(&tail), vec![MessageKind::AudioConfig, MessageKind::AudioFrame]);
}

#[test]
fn a_source_that_cannot_capture_is_a_problem_in_the_window() {
    let audio = ScriptedAudio::default();
    let runtime = runtime_with(&audio);
    runtime.shared.lock().sessions.insert(1, slot("phone"));
    audio.fail_with("no output device");
    runtime.shared.lock().pump_audio();
    assert!(runtime.shared.lock().problems.values().any(|text| text.contains("no output device")));
}
