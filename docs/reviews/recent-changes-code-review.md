# Code review of the recent changes

Reviewed 2026-10-13. Fixed point `fa01abbc` (the commit that added the Android and Windows reviews), diff
`git diff fa01abbc...HEAD`: 629 files, 37,149 insertions, 166 commits. The diff is too large for one reader, so each axis
was run once per area (relay, Apple, Android, Windows), eight read-only reviewers in all. The two axes are kept apart and
not re-ranked against each other. Within each area findings are most severe first.

Standards sources: `CLAUDE.md`, `AGENTS.md`, `android/README.md`, `windows/README.md`, `relay/README.md` plus the
smell baseline (judgement calls only). Spec sources: the review docs in this folder, `docs/analytics-events.md`,
`docs/protocol.md`, `docs/protocol/relay.md`, `docs/TODO.md` and the requirements stated during the work.
`docs/agents/issue-tracker.md` does not exist; the spec sources were passed directly, so nothing was skipped for it.

Already fixed during this review (not repeated below): the Android control payload cap now applies only until the
handshake is done (a regression against shipped Mac hosts, which send larger catalogue and terminal messages); two build
warnings; the Android and Windows relay vector tests. Not a finding: `PanelWindowEntrance.swift` was reported as scope
creep but was removed by the popover change.

## Standards

### Relay

1. **High (hard, privacy).** `src/signalling.rs:433`, `:589`, `src/tcp_relay.rs:77`: debug logs write raw client IPs
   (`peer = %peer_address.ip()`), against the relay's promise to log no addresses. Fix: drop the field or log `tag(ip)`.
2. **Medium (hard).** `src/signalling.rs` is 2161 lines (about 1268 non-test) and `handle` is about 150 lines, `serve`
   about 100, `main` about 300. Fix: split by message family and move backend wiring into `build_*` functions.
3. **Medium (hard).** `src/signalling.rs:~600-614` has a ten line bold design essay as a comment. Keep one line.
4. Smells: duplicated refusal blocks (`signalling.rs:985-1027`, a `refuse(reason)` helper), `Totals` type not used in
   `usage_log.rs` and unnamed `(window, seconds)` tuples, `host =` versus `host_id =` field name (`signalling.rs:1162`),
   three proof failure branches that want a `ProofOutcome` enum, `Redactor` wider than needed, `main` repeats a
   ready/failed/disabled trio three times.
5. Defects: the mirrored usage totals are unbounded within one window for more than 40k ids (`usage_log.rs:219-222`);
   confirm the four `.lock().unwrap()` in `fcm_auth.rs:223-274` are test only; move the constant assert into a `const {}`.

### Apple

1. **High (hard).** Files over the limit: `HostServer.swift` 664 lines (580 at the fixed point), `ClientSession.swift` 640,
   plus `SSHSession` 521, `SessionModel+Connection` 485, `HostModel+Lifecycle` 472, `VideoEncoder` 459, `SessionModel` 434,
   `MacSession+Events` 427, `MacSession` 419, `ClientConnection` 377, `Handshake` 341, `HostSession+Handshake` 333.
   `accept()` is far over 40 lines. Fix: `HostServer+Accept`, `HostServer+Pairing`.
2. **Medium (hard).** `HostServer.swift:24-27` widened queue confined state (`controlSessions`, `pendingRelayBridges`,
   `activeRelayBridges`, `tunnelMatcher`, `pairingGate`, `RelayTunnel`) from private to internal. Fix: keep private.
3. **Medium (hard).** `RelayHostRegistration.swift:187,197,273,289,307` and `HostServer.swift:~569` pass plain English
   status text to the Activity feed. Being fixed by the localization pass.
4. **Low (hard).** `HostSessionFacts.swift`: a doc comment sits on the wrong member, and a global singleton is read from
   three places.
5. Smells: `HostServer.accept()` wires about 15 closures with the same weak-self guard (a `bind(to:)` helper), string stages
   where closed enums exist (`HostTelemetry.pairingRefused(stage: "confirm")`), `chatsChanged` and `presenceChanged` have
   identical bodies, `LiveActivityTokens` is thin forwarding, `SendWindowFailure(message: nil)` encodes cancellation as nil.
6. **Defect (medium, concurrency).** `PinStoreAlarm.raise` is called while `ClientPinStore.lock` is held (via `reload`),
   breaking the rule never to call out under a lock; a handler that re-enters the store would deadlock. Record the status
   under the lock and raise after unlock.
7. **Defect (medium).** `GroupProcess.terminateGroup`: the delayed SIGKILL (`DispatchQueue.global().asyncAfter(5s)`) fires
   unconditionally. After the group exited cleanly its id can be recycled, so the kill can hit an unrelated group. Skip it
   when no member remains (`kill(-pgid, 0)` fails).
8. **Defect (medium).** `HostServer.stop()` calls `activityPublisher.hostStopping()` which waits up to 1.5 s with
   `group.wait`, from the main actor: the Mac UI freezes on every stop or quit. Wait off the main thread or make it async.
9. **Defect (medium).** `RelayHostRegistration.notifyActivity` sends each push in its own `Task.detached`: two quick
   updates can arrive reversed and leave a card stale. Send through one serial queue.
10. **Defect (medium).** `CaptureRecovery.plan` and `hold(task)` take the lock twice: a second failure between them
    schedules a second rebuild, and `attemptStarted` or `reset` can lose or fail to cancel a task, so two
    `rebuildCapture` calls can run on a flapping display. Create and hold the task inside one call or use a generation token.
11. **Defect (low).** `RelayHostRegistration.send` logs a device push token with `privacy: .public`; `SendWindow` waits in a
    non cancellation aware continuation; `Relay unavailable: \(error.localizedDescription)` can put URL details in the feed.

### Android

1. **Medium-high (defect).** `DownloadCoordinator.cancel()`/`fail()` on the "peering-downloads" executor: `sink.discard()`
   is unguarded, and `flush()`/`complete()` catch only `IOException`. A SAF provider that throws `SecurityException` (grant
   revoked, provider died) reaches the default handler and kills the app. Catch `Exception` in `SessionDownloads.settle`,
   mark the destination failed, make `discard` best effort.
2. **Medium (defect).** `SurfacePicture.guarded()` sets `decoder = null` on a `RuntimeException` without releasing it, and
   `onSurfaceAvailable` overwrites a live decoder: hardware decoder slots leak until `createDecoderByType` fails.
3. **Medium (defect).** `CodecDecoder.queue()` calls `dequeueInputBuffer(10_000)` on the Main thread: up to 10 ms of jank per
   frame when input slots are full. Use a zero timeout and drop to the keyframe policy, or decode on a thread.
4. **Medium-low (defect).** `SessionDownloads` after `writer.shutdown()`: a late `execute` throws
   `RejectedExecutionException` on the caller. Guard with a closed flag.
5. **Low-medium (defect).** `KeystoreBlobStore.put()`: fixed temp name `$name.tmp`, no lock, no cleanup on failure; two
   concurrent puts can publish a corrupt blob which then reads back as a permanent loss. Make it synchronized, unique temp
   name, delete in `finally`.
6. Low: NSD resolve timeout leaves the listener registered (`NsdDiscovery.kt resolveOnce`); `SharedFiles.write` is not
   atomic; `MainActivity.followSession` returns silently when `wiring` is null.
7. Hard (low): `LinkRunner.startSession` is 44 lines; `PreviewReply` English text not in string resources;
   `NsdDiscovery` uses raw `Log.d` for service names in release builds.
8. Smells: `launchLinkTask` swallows the exception without a note, `submitCode` in `SessionController` is a pass through,
   `PreferenceWrites.shared` hides a global, companion object in the middle of `PreviewProxyClient`.

### Windows

1. **Medium (defect).** `host/src/runtime/video.rs:229-243` with `shared.rs:79`: the std `Mutex<HostState>` is held across
   capture and encode, and connection tasks, handshakes and input lock the same mutex on a single thread runtime. A slow
   encode freezes input. Take inputs under the lock, run capture and encode outside it, re-lock to publish.
2. **Medium (defect).** `supervise.rs:37`: `catch_unwind` wraps a closure holding the `HostState` guard, so a panic poisons
   the mutex and `Shared::lock` silently continues on half updated state. Reset the coordinator after a caught panic.
3. **Medium (hard).** Functions over 40 lines (`HostRuntime::new` 57, `serve_connection` 55, `pump_video_pass` 49,
   `connection.rs run` 45, `register` 44, `chunks.rs ingest` 44) and files over 300 (`runtime.rs` 343, `connection.rs` 317,
   `coordinator.rs` 305).
4. **Medium (hard, dead code).** The terminal hooks (`host/src/hooks/*`, `peering_core::terminal::hooks`) are still unwired.
5. Low: latent lock order (control then state then control) in `video_pass`; unbounded relay ask channels
   (`runtime.rs:222`, `relay.rs:89`, `relay_lane.rs:41`); three `expect` on serialisation without a line saying why.
6. CI gap: clippy does not run on `peering-platform` and the host. Add `cargo clippy --workspace --all-targets`.
7. Smells: `HostState` is a 25 field god struct, `pump_video_pass` feature envy, inline `lock().unwrap_or_else(into_inner)`
   three times, problem sources as `&'static str` keys, bare f64 seconds.

## Spec

### Relay

1. **Medium-high.** `signalling.rs:500-513`: per-IP limits can be sidestepped. The relay trusts `CF-Connecting-IP`, then the
   left-most `X-Forwarded-For`, but a client reaching nginx without Cloudflare can send either forged. Verified against the
   live nginx: it sets `X-Real-IP` from the true connection address (Cloudflare ranges plus `real_ip_header`), so
   `X-Real-IP` is the only safe header. Fix: trust `X-Real-IP` by default, make the header configurable, test the spoof.
2. **Medium.** Peer addresses are still logged (same sites as Standards 1).
3. **Medium.** `tools/deploy-relay.sh healthy()` probes only the web listener's `/healthz`: if the web listener fails to
   bind a good deploy is rolled back, and the web task is not in the supervised set. Probe the signalling port too and
   supervise the web task. No test covers the script.
4. **Low-medium.** `activity.rs:~213`: a half alert (title without body) on update or end is silently dropped and a test
   enshrines it; a `notifyActivity` that fails serde returns a generic `error protocol` with no `activityRefused` and no
   `requestId`. Return `invalidPayload` and decode leniently.
5. **Low.** The activity rate limit lives per connection (64 tokens, a 65th silently dropped), so many connections multiply
   it. `DeviceTokenNotForTopic` is reported as `invalidToken` (the host then discards a valid token): report `rejected`.
   `requestId` limit is enforced as 64 bytes not characters. Per-IP limits are off with no warning if the proxy sends no
   headers. The referral address table is cleared wholesale at its cap.
6. Open items already documented: Apple receipts are bearer tokens, `referralStatus` still mints a code on first ask.

### Apple

1. **Medium-high.** `LiveActivityPushPlanner.swift:92,127-132,197`: a finished card stays about 60 minutes, not 30: the planner
   waits 30 minutes after the chat settles and then sends `end` with `dismissalSeconds` 1800. The test locks it in. Send the
   `end` with dismissal 0 at the 30 minute mark, or at settle time with 1800.
2. **Medium.** `pin_store_unreadable` is lost on a cold start with a locked Keychain: `SessionModel()` reads the store before
   `PinStoreAlarm` is installed, and later reads do not raise again. Buffer the first raise until install.
3. **Medium.** `ClientPinStore.load`: a corrupt blob with no good backup is returned as absent and the next pairing overwrites
   it, with no alarm. Return `unreadable` when data exists but cannot be decoded, add the test.
4. **Medium-low.** `URLCommandRouter.confirm` / `.alert` sit outside the lock view: a pending `disconnect` confirm can be
   accepted behind the app lock. Drop or hold the command when locked and clear `confirming` on lock.
5. **Low-medium.** `ControlTextPolicy` measures raw UTF-8 not the escaped JSON: 48 KB of quotes, slashes or control
   characters exceeds 64 KB encoded and the host drops the session. Measure the encoded payload or lower the cap.
6. **Low-medium.** `.inactive` counts as leaving the foreground (Control Center, Face ID, app switcher pause the video), and
   a notice dropped while the session is not ready is never resent on ready. Send on `.background` or debounce, resend on ready.
7. **Low.** Host sentences (file transfer, busy, zip size) and Live Activity alert text are localized in the Mac's language
   while the phone matches English wire text. Send English or codes and translate on the phone.
8. **Low.** Menu bar: the popover is shown without activating the app (a transient popover may not become key for text fields),
   `openWindow` is captured only after the main window first appears, no tests.
9. **Low.** `end` ignores the one second gap, the gap is per kind not per token; backpressure covers terminal output only;
   the delayed SIGKILL (Standards 7); `host_error` falls back to the newest session's `session_ref`.

### Android

1. **Medium.** The exported `MainActivity` still parses `peering://` data from any explicit intent; `LockedLinkQueue` defers it
   but nothing authenticates the sender. Carry a per-install nonce in the widget `PendingIntent` or use a non exported trampoline.
2. **Medium.** `HubActivity` never applies `ScreenSecurity`, so FLAG_SECURE is absent while it is on top (recents and
   screenshots can show Mac content). Apply it from the same session flow.
3. **Low-medium.** Every production dial uses `pin = null, firstPairing = true`, and the LAN video lane never compares the
   observed key: a spoofed video address would be accepted. Pass the stored pin to video routes or compare `peerPublicKey()`.
4. **Low.** `NsdDiscovery` and `CodecDecoder` log addresses and throwables with plain `Log` in release; `sessionReady`
   `remainingSeconds` is parsed but dropped by `RelayConnect.awaitSession` and `RelayAllowance` is still guessed locally;
   after a backgrounded network move a dead socket can sit 30 s.
5. **Low.** `DecoderRecovery`: `onPictureDecoded()` resets the failure count, so a stream that decodes one frame then fails on
   every rebuild never reaches the cap of 3.
6. Verify: a 64 KiB figure for Windows terminal output events (see Windows 2 below) was a real conflict, fixed on the Android
   side. Lone `receive()` is bounded to 10 s (document it).

### Windows

1. **Medium.** A hung encode still freezes the host (only a monitor thread reports it). Run encode off thread with a deadline
   (needs a multithread protected D3D device) or restart the process from the monitor.
2. **Medium.** `outbound.rs push/drop_stale`: dropping queued video discards the dropped count, so no resync is requested and
   the phone decodes a smeared picture until the next keyframe. Request a resync when `dropped > 0`. Also: terminal output
   events carry up to 64 KiB raw, about 87 KiB once encoded, against the documented 64 KiB rule: chunk at 32 KiB.
3. **Medium-low.** `agent_pump.rs:33` has no `catch_unwind`: a panic ends the whole host. The no frames watchdog and recovery
   report go out as `error sourceUnavailable` and not as a standing notice that clears.
4. **Medium-low.** `recovery.rs STALL_SECONDS`: capture is rebuilt every 30 s (doubling to 300 s) on a still desktop, which
   yields no frames on a healthy host. Probe by re-opening the duplication before escalating.
5. **Low-medium.** `control.rs end_client_sessions` and `stop_sessions` do not call `refresh_bitrate_ceiling`; pairing can be
   squatted (`AwaitingApproval` counts Ping and Pong as life, no absolute limit); `HoldGuard::heard` is global so a live
   second phone prevents releasing a dropped phone's keys; DPAPI entropy is a constant, the no entropy fallback is never
   re-sealed; autostart removal can report success without removing; the paired list recovery is a manual file delete.
6. Capability honesty: `supports_file_browser` is set unconditionally while writes are refused; `supports_agent_chat` and
   `supports_agent_list` are set even without a `claude` binary. The hooks are still dead code.
7. Workflow: `windows.yml` has both `tags: windows-v*` and a `paths:` filter, so a release tag on a commit that does not touch
   those paths may not trigger; the installer version comes from `Cargo.toml` and not the tag; the Linux job has no cache.
