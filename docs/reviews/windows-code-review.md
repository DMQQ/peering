# Windows code review

Reviewed 2026-10-12 at the tip of `monorepo` (whole `windows/` folder, not a diff). Two axes, kept separate: standards and
correctness, then spec conformance. The logic crates were checked on a Mac:
`cargo clippy --locked -p peering-wire -p peering-core -p peering-agent -p peering-net --all-targets` is clean except one
warning (`empty_line_after_doc_comments`, `crates/peering-core/tests/relay_flow.rs:40`), and `cargo test --locked` passes for
the same packages. `peering-platform` and `host` do not build on a Mac, so every `unsafe`, COM, Win32 and host finding comes
from reading only. Nothing in the Windows-only code has ever run on Windows. Findings are ranked most severe first inside
each axis. HARD means a documented standard or a real defect, JUDGEMENT means a smell.

## Standards and correctness

Clean results: no em dashes, no `unwrap`, `expect` or `panic` reachable from network input (the only non-test `expect`s are
on infallible serialisation), frame decoding is bounded (16 MiB cap before buffering, 64 KiB control payload), TLS 1.3
only, the accept-any-client verifier still validates the handshake signature and the pin is checked after.

1. **High, HARD.** `host/src/main.rs:30-40`, `host/src/runtime.rs:278`. The result of `run_host` is inspected only if the host
   fails before `ready` is sent, but port 51515 is bound and mDNS started after `ready`. Failure: a second instance, or any
   app on 51515, makes the host silently never listen while the tray looks healthy. Fix: send the handle only after bind and
   advertise succeed, or surface the join result as a "host stopped" state.
2. **Medium, HARD.** `host/src/runtime/files.rs:12-40`, `crates/peering-core/src/files/path.rs:43`. Blocking `std::fs` runs on
   the single `current_thread` runtime that also serves every connection and the video pump. `roots()` probes A: to Z:, and a
   disconnected network drive can stall for seconds. `path::is_name` accepts reserved device names (`CON`, `NUL`, `AUX`,
   `COM1`, `con.txt`, trailing dots). Failure: a paired phone asks `ReadFile` for `/C:/con` and the host freezes, all sessions
   time out. Fix: reject reserved names and run filesystem calls under `spawn_blocking` with a timeout.
3. **Medium, HARD.** `host/src/runtime/listener.rs:20-37`. No timeout on `tls.accept`, no cap on pre-auth connections, no
   per-address limit, and any inbound frame resets liveness, so a peer pinging every 25 s stays unauthenticated forever.
   Failure: a LAN host opens thousands of stalled handshakes and exhausts descriptors. Fix: about 10 s handshake timeout, a
   cap, and only authorising frames count as proof of life before authorisation.
4. **Medium, HARD.** `host/src/runtime/relay.rs` (`connect`, `dial`, about 118-160). No timeouts on the websocket connect, the
   TCP connect or `relay_accept`, and `dial` is spawned once per `sessionReady` with no cap. Failure: a black-holed relay
   stalls tick handling (reconnect, ping) for the OS timeout. Fix: a timeout per stage and a cap on concurrent dials.
5. **Medium, HARD.** Unbounded queues from a peer: `connection.rs` outbound `mpsc::unbounded_channel`, `relay_lane.rs`,
   `relay.rs` asks and notifications. Failure: a paired phone that stops reading while video flows grows memory without
   limit. Fix: bounded channels, drop-oldest for video, close on a high-water mark.
6. **Medium, HARD.** `crates/peering-core/src/pairing.rs` (`apply_event`, `request_approval`, `forget_session`). Any LAN peer
   that completes TLS can start pairing, each `PairingCode` event overwrites the single `offer`, approvals append without
   limit, and `forget_session` never clears a stale offer. Failure: spam replaces the real phone's code, or floods approval
   prompts. Fix: one active pairing per host, cap pending approvals, clear the offer when its session ends.
7. **Medium, HARD (key handling).** `crates/peering-platform/src/dpapi/sys.rs`, `dpapi.rs`. DPAPI is called with no entropy,
   so any process of the same user can unseal the identity key and push tokens. Plaintext copies are never zeroed
   (`HostIdentity.pkcs8`, `copy_and_free`, `PrivatePkcs8KeyDer` copies in `tls.rs`), and `SecretFiles::write` sets no
   restrictive directory ACL. Fix: an app entropy blob, `zeroize`, tighten the directory ACL.
8. **Low-medium, HARD.** `host/src/hooks/installer.rs` (`write_settings`). `fs::write` truncates the user's Claude
   `settings.json` in place, a crash mid-write corrupts it, a backup exists only after the first change, and the hook token
   is plaintext in the `.cmd` script. Fix: write a temp file in the same directory and rename.
9. **Low, HARD.** Dead code: `host/src/hooks/*` and `HookBroker` (`crates/peering-core/src/terminal/hooks/broker.rs:57`) have
   no callers outside tests. The server design is sound (loopback bind, constant-time token check, size caps, 5 s read
   deadline) apart from no limit on concurrent connections. Fix: wire it or gate it behind a feature.
10. **Low, HARD.** `host/src/firewall.rs`. The elevated helper trusts any port in argv (0 is accepted), the rule has no
    `remoteip=localsubnet`, the program path is in a user-writable directory, and `delete rule name=` removes every rule with
    that name. Fix: restrict to the subnet, reject port 0, verify the port is the fixed default.
11. **Low, HARD.** `crates/peering-platform/src/keyboard.rs` (`record_chord`, `release_all`). A repeated key down duplicates the
    chord list, and `finish()` in `connection.rs` releases all keys when any session ends, even if another live session holds
    them. Fix: dedupe, release only when the last session leaves.
12. **Low, HARD.** Silent errors: `relay.rs send_notifications` drains the queue before sending, so a mid-send failure loses the
    rest; `mouse/sys.rs` and `keyboard/sys.rs` discard the `SendInput` count; `dda/sys.rs release_frame` ignores errors.
13. **Low, HARD.** Windows-only code that only compiles on Windows and was never exercised: `firewall::request_rule_elevated`,
    the autostart `reg.exe` calls, the `SecretFiles` DPAPI path.
14. **Low, HARD (standards).** Files marginally over about 300 lines: `host/src/runtime.rs` (305),
    `crates/peering-wire/src/handshake.rs` (307), `crates/peering-core/src/video/coordinator.rs` (306), plus the clippy warning.
15. **Judgement (Feature Envy, Primitive Obsession).** `Shared.lock()` hands out the whole `HostState`, and `pump_video` holds
    the std `Mutex` while capturing and encoding on the async thread, which also costs latency. Ids, tokens and ports are bare
    `String`, `u64`, `u16` throughout.
16. **Judgement (Duplicated Code, Middle Man).** `browse_failure` and `transfer_failure`; three `SecretStore` adapters
    (`SharedSecrets` duplicates the trait for an `Arc`); `relay_accept` in `tls.rs` is a one-line wrapper of `accept`.
17. **Judgement (naming, comments).** `Flow::Open/Closed`, `Handler`, `size_of` and `size_of_total` in `files/browse.rs`
    (shadows `std::mem::size_of` in name); several comments retell code.

## Spec conformance

Specs: `docs/plans/android-and-windows.md` and `-tasks.md`, `docs/protocol.md`, and the Mac host as the behaviour reference.
Wire models (commands, handshake, relay messages, source and catalogue, terminal enums) match `RemoteCore` field for field.
`WIN-098` and `XOP-001..004` are correctly still todo. The defects are in the runtime glue.

1. **High.** The LAN video connection is reaped after 30 s. `host/src/runtime/connection.rs:167` (`on_tick`) with
   `crates/peering-core/src/session/state.rs:24-30`: a role 2 connection parks at `Failed`, which maps to `Unauthenticated`
   (30 s silence limit), and the client never sends on the video socket. Swift skips video connections
   (`HostServer.swift:330`). Failure: LAN video dies about 30 s in. Fix: skip the liveness verdict when `video_for_session`
   is set.
2. **High.** A late-attaching video connection never gets `videoConfig` or a keyframe. `connection.rs:231` (`attach_video`)
   only stores the sender, and the first pump sends config and keyframe before the client opens the role 2 socket
   (`video.md` section 1). Failure: black picture on LAN. Fix: re-arm config and a keyframe in `attach_video`.
3. **High.** No default capture source. The only `set_source` call is a client command (`dispatch.rs:108`), and `sending()`
   requires a source. Swift defaults to the main display (`VideoCoordinator+Capture.swift:9`). Failure: a client that sends no
   `setCaptureSource` gets no picture. Fix: start the primary display on attach, call `forget_chosen_source_if_idle`
   (`coordinator.rs:99`, never called), and stop capture when the last client leaves.
4. **High.** `TCP_NODELAY` is never set (`listener.rs:18`, `relay.rs:169`). `docs/protocol.md` section 2 requires it on every
   socket, and Nagle costs about 40 ms per hop. Fix: `set_nodelay(true)` on accepted sockets and the relay stream before TLS.
5. **Medium-high.** A removed device keeps its live session. `control.rs:156` `Forget` only calls `pairing.revoke`; Swift ends
   the sessions (`HostServer.swift:268`). Failure: a forgotten phone keeps screen and input access until it disconnects. Fix:
   drain that client's sessions and release input after the revoke.
6. **Medium.** The secure-desktop notice (WIN-075, marked done) is never sent: `peering-platform/src/session_state.rs` is not
   referenced from `host/` or `peering-core`, and no notice frame is built. Failure: a UAC prompt or lock screen shows a
   frozen picture with no explanation. Fix: wire it into the pump, use `watchdog_expired` (`coordinator.rs:200`, unused).
7. **Medium.** Stopping hosting never sends `error hostStopped` (`handshake.rs:163` is unused), so clients reconnect in a loop
   (`docs/protocol.md` section 9). Fix: send and flush the error frame before closing.
8. **Medium.** A video connection attaches to an arbitrary session (`connection.rs:231` uses `iter_mut().find` over a
   `HashMap`), and `finish` (`connection.rs:245`) detaches video and releases input unconditionally. Failure: a reconnecting
   phone loses video or input when its old session closes. Fix: choose the newest slot, detach only when no other slot has
   the same client id.
9. **Medium.** `supportsFileBrowser` is advertised unconditionally (`connection.rs:221-223`) but `files/browse.rs:44` swallows
   `beginWrite`, `writeChunk` and `changeFile`. Failure: upload, rename and delete hang with no reply, including the Android
   "attach files" feature. Plan 1.8 says declare only what is implemented. Fix: reply with a failure now.
10. **Medium.** Agent folder browse is not wired and agent sessions die with the connection. `peering-agent/src/manager.rs:69`
    returns "not supported" for Browse, ListResumable and Resume, `browse.rs` (WIN-056 "done") is never called, and the manager
    is per connection (`connection.rs:43`) where Swift holds one per client. Failure: the client's folder picker fails, and a
    reconnect kills the claude children and loses the chat list. Fix: hold the manager in `HostState` keyed by client id and
    call `browse::list`.
11. **Low-medium.** The 2 Mbps fallback cap is global (`video_requests.rs:44-45`) and `finish()` never resets it. Fix: minimum
    over sessions, reset on close.
12. **Low-medium.** Firewall coverage is thin: TCP only, `profile=private`, nothing runs until the user clicks Fix firewall, and
    mDNS UDP 5353 is not covered. Failure: a new Wi-Fi network defaults to Public and LAN connections time out.
13. **Low.** Unwired or unrequested pieces: `Advertiser::set_connected_clients` is never called, hooks are test-only, codec and
    platform hints from the hello are stored but unused, frame rate is not persisted (`settings.rs` unused), `topRowAction` is
    not implemented, bind is `0.0.0.0` only (no IPv6 listener), relay notifications are lost on a mid-send failure.

Checked and consistent with the spec or Swift: handshake order and limits, SAS and pairing order, pings and liveness
(60/30/120 s), the 16 MiB frame guard, relay message shapes, sealed datagram lane, and the capability flags
`supportsVideoPause` and `supportsLockScreen`. Only items 3, 9 and 10 involve a flag the host sets while the feature is partial.
