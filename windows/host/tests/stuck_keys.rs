mod support;

use peering_core::ports::clock::Clock;
use peering_wire::command::{Modifiers, MouseButton, RemoteCommand};
use support::*;

fn pressed(harness: &Harness) -> usize {
    harness
        .input
        .lock()
        .expect("the input is not poisoned")
        .applied()
        .iter()
        .filter(|(command, _)| matches!(command, RemoteCommand::KeyUp { .. } | RemoteCommand::MouseUp { .. }))
        .count()
}

#[test]
fn keys_a_silent_phone_left_down_are_released_after_the_ttl() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&RemoteCommand::KeyDown { key_code: 0x10, modifiers: Modifiers::NONE }).await;
        phone.send_command(&RemoteCommand::MouseDown { button: MouseButton::Left }).await;
        phone.sync().await;

        harness.clock.advance(4.0);
        harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
        assert_eq!(pressed(&harness), 0, "four seconds of silence is not yet a drop");

        harness.clock.advance(2.0);
        harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
        assert_eq!(pressed(&harness), 2, "the key and the button are lifted");
    });
}

#[test]
fn a_phone_that_keeps_pinging_keeps_what_it_holds() {
    run(async {
        let harness = harness();
        let mut phone = paired_phone(&harness.runtime).await;
        phone.send_command(&RemoteCommand::KeyDown { key_code: 0x10, modifiers: Modifiers::NONE }).await;
        phone.sync().await;
        for _ in 0..10 {
            harness.clock.advance(3.0);
            phone.sync().await;
            harness.runtime.pump_video(harness.clock.now_seconds()).expect("the pump runs");
        }
        assert_eq!(pressed(&harness), 0);
    });
}
