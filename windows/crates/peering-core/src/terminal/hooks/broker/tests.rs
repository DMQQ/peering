use std::sync::atomic::{AtomicU64, Ordering};

use super::*;

#[derive(Default)]
struct FakePhones {
    tokens: Vec<String>,
    pushes: Mutex<Vec<HookPush>>,
}

impl Phones for FakePhones {
    fn tokens(&self) -> Vec<String> {
        self.tokens.clone()
    }

    fn push(&self, push: HookPush) {
        self.pushes.lock().expect("lock").push(push);
    }
}

struct FakeClock(Mutex<f64>);

impl Clock for FakeClock {
    fn now_seconds(&self) -> f64 {
        *self.0.lock().expect("lock")
    }

    fn unix_seconds(&self) -> u64 {
        0
    }
}

type Replies = Arc<Mutex<Vec<Option<Vec<u8>>>>>;

struct Rig {
    broker: HookBroker,
    phones: Arc<FakePhones>,
    clock: Arc<FakeClock>,
    replies: Replies,
}

fn rig(tokens: &[&str]) -> Rig {
    let phones = Arc::new(FakePhones { tokens: tokens.iter().map(|token| (*token).to_owned()).collect(), ..Default::default() });
    let clock = Arc::new(FakeClock(Mutex::new(0.0)));
    let counter = AtomicU64::new(0);
    let broker = HookBroker::new(
        phones.clone(),
        clock.clone(),
        Box::new(move || format!("approval-{}", counter.fetch_add(1, Ordering::Relaxed))),
    );
    Rig { broker, phones, clock, replies: Arc::default() }
}

impl Rig {
    fn handle(&self, event: &HookEvent) {
        let replies = self.replies.clone();
        self.broker.handle(event, Box::new(move |reply| replies.lock().expect("lock").push(reply)));
    }

    fn replies(&self) -> Vec<Option<Vec<u8>>> {
        self.replies.lock().expect("lock").clone()
    }

    fn pushes(&self) -> Vec<HookPush> {
        self.phones.pushes.lock().expect("lock").clone()
    }

    fn set_time(&self, seconds: f64) {
        *self.clock.0.lock().expect("lock") = seconds;
    }
}

fn permission(tool: &str, command: &str) -> HookEvent {
    HookEvent {
        kind: HookKind::PermissionRequest,
        session_id: "session-1".to_owned(),
        directory: Some("/Users/x/app".to_owned()),
        tool_name: Some(tool.to_owned()),
        detail: Some(command.to_owned()),
        message: None,
    }
}

#[test]
fn a_command_is_held_and_pushed_with_allow_and_deny() {
    let rig = rig(&["t1"]);
    rig.handle(&permission("Bash", "npm test"));
    assert!(rig.replies().is_empty());
    let push = rig.pushes().remove(0);
    assert_eq!(push.title, "Claude Code in app asks");
    assert_eq!(push.body, "npm test");
    assert_eq!(push.action.map(|action| action.category), Some(TOOL_CATEGORY));
}

#[test]
fn allow_answers_the_held_hook_once() {
    let rig = rig(&["t1"]);
    rig.handle(&permission("Bash", "npm test"));
    let approval_id = rig.pushes()[0].action.clone().expect("an action").approval_id;
    assert!(rig.broker.resolve(&approval_id, Answer::Allow));
    assert_eq!(rig.replies(), vec![Some(permission_reply(HookDecision::Allow))]);
    assert!(!rig.broker.resolve(&approval_id, Answer::Deny));
}

#[test]
fn deny_answers_with_a_deny() {
    let rig = rig(&["t1"]);
    rig.handle(&permission("Bash", "rm -rf build"));
    assert!(rig.broker.resolve("approval-0", Answer::Deny));
    assert_eq!(rig.replies(), vec![Some(permission_reply(HookDecision::Deny))]);
}

#[test]
fn choosing_an_option_hands_the_question_back_to_the_terminal() {
    let rig = rig(&["t1"]);
    rig.handle(&permission("Bash", "ls"));
    assert!(rig.broker.resolve("approval-0", Answer::Choose));
    assert_eq!(rig.replies(), vec![None]);
}

#[test]
fn a_request_nobody_took_falls_back_to_the_terminal_dialog() {
    let rig = rig(&["t1"]);
    rig.handle(&permission("Bash", "npm test"));
    rig.set_time(HOLD_SECONDS - 1.0);
    assert_eq!(rig.broker.expire(), 0);
    assert!(rig.replies().is_empty());
    rig.set_time(HOLD_SECONDS);
    assert_eq!(rig.broker.expire(), 1);
    assert_eq!(rig.replies(), vec![None]);
}

#[test]
fn an_answer_after_the_timeout_finds_nothing_to_answer() {
    let rig = rig(&["t1"]);
    rig.handle(&permission("Bash", "npm test"));
    rig.set_time(HOLD_SECONDS + 5.0);
    rig.broker.expire();
    assert!(!rig.broker.resolve("approval-0", Answer::Allow));
    assert_eq!(rig.replies().len(), 1);
}

#[test]
fn no_phone_means_no_wait() {
    let rig = rig(&[]);
    rig.handle(&permission("Bash", "npm test"));
    assert_eq!(rig.replies(), vec![None]);
    assert!(rig.pushes().is_empty());
}

#[test]
fn a_question_is_pushed_but_never_held() {
    let rig = rig(&["t1"]);
    rig.handle(&permission("AskUserQuestion", ""));
    assert_eq!(rig.replies(), vec![None]);
    assert_eq!(rig.pushes()[0].action.as_ref().map(|action| action.category), Some(OPEN_CATEGORY));
    assert_eq!(rig.pushes()[0].body, "Needs your approval.");
}

#[test]
fn a_command_too_long_to_read_is_left_to_the_app() {
    let rig = rig(&["t1"]);
    rig.handle(&permission("Bash", &"x".repeat(400)));
    assert_eq!(rig.replies(), vec![None]);
    let push = rig.pushes().remove(0);
    assert_eq!(push.body.chars().count(), MAXIMUM_BODY_CHARACTERS);
    assert_eq!(push.action.map(|action| action.category), Some(OPEN_CATEGORY));
}

#[test]
fn an_idle_notification_is_a_plain_push() {
    let rig = rig(&["t1", "t2"]);
    let idle = HookEvent {
        kind: HookKind::Notification,
        session_id: "s".to_owned(),
        directory: None,
        tool_name: None,
        detail: None,
        message: Some("Claude is waiting for your input".to_owned()),
    };
    rig.handle(&idle);
    let pushes = rig.pushes();
    assert_eq!(pushes.len(), 2);
    assert_eq!(pushes[0].body, "Claude is waiting for your input");
    assert_eq!(pushes[0].title, "Claude Code");
    assert!(pushes[0].action.is_none());
    assert_eq!(rig.replies(), vec![None]);
}

#[test]
fn another_event_is_answered_with_nothing() {
    let rig = rig(&["t1"]);
    let mut stop = permission("Bash", "x");
    stop.kind = HookKind::Other("Stop".to_owned());
    rig.handle(&stop);
    assert_eq!(rig.replies(), vec![None]);
    assert!(rig.pushes().is_empty());
}
