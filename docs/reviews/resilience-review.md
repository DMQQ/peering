# Resilience review: safety guards and retry handling

Reviewed 2026-10-12 at the tip of `monorepo`, read only, five areas: the iPhone app and its packages, the Mac host,
the Android app, the relay, and the Windows host. Nothing was built or run for this review. Each area was read by a
separate pass, so the reading is sampled, not exhaustive. Items already fixed by the earlier Android and Windows
reviews (`android-code-review.md`, `windows-code-review.md`) are not repeated. Within each area, findings are ranked
most severe first. HIGH items can lose data, drop sessions on ordinary input, or open a security gap. A few findings
repeat across areas and are grouped under "Cross cutting" at the end.

## iPhone app, RemoteCore, SSHCore, MacCastKit

1. **HIGH. Pasting more than 64 KB kills the session.** `MacCast/Session/SessionModel+Clipboard.swift:37-40,124`,
   `ClientSession.sendTerminal` and `sendAgent`. Only images are chunked. The host rejects a control payload over
   `maxControlPayload` (64 KB, `HostSession+Commands.swift:13,37,45`) as malformed and drops the session, and the resume
   ladder reconnects and the retried tap drops it again. Fix: cap text at about 48 KB on the phone with a message, or chunk
   it like images, and apply the same cap to terminal input and agent prompts.
2. **HIGH. A failed Keychain read is treated as an empty pin store.** `RemoteCore/ClientPinStore.swift:21,76-136`,
   `PeerPinning.swift:92-100`, `StoreManager.swift:384-398`. A transient `errSecInteractionNotAllowed` or a corrupt blob
   reads as empty, and the next pairing writes the whole dictionary, erasing every other pin. Fix: distinguish unreadable
   from absent, refuse to record while unreadable, keep a backup blob.
3. **HIGH. Uploads have no back pressure.** `Terminal/MacSession+FolderUpload.swift:235-251`,
   `ClientConnection.swift:228`. Chunks are sent without waiting for completion, so a fast disk and a slow relay grow
   memory until the system kills the app, keystrokes queue behind the data, errors are never seen and the Mac is never told
   to abort a half written file. Fix: await completion per chunk or cap bytes in flight (about 1 MB), send an abort on
   failure, add a cancel button.
4. **MEDIUM. No timeout on the relay signalling socket or the application handshake.** `RelaySignalling.swift:22-78`,
   `ClientSession.swift:219-348`, `ClientSession+DirectPath.swift:30-38`. Only the TLS dial has a 10 s timeout. A relay or Mac
   that stalls after the connection is up leaves "Connecting" forever, and one hung `discoverPeer` call stops direct path
   probes. Fix: a 15 s race around `requestSession`, a handshake deadline, time box `discoverPeer`.
5. **MEDIUM. A pin mismatch during a resume is retried silently.** `MacSession+Events.swift:12-26`, `DropStreak.swift:46-48`.
   Key changed, host id mismatch, no pin and protocol mismatch re-enter the ladder and end as a generic "gave up", so the
   user never learns the Mac's key changed. Fix: treat those reasons as terminal and show the re-pair message.
6. **MEDIUM. File download trusts offsets and sizes from the Mac.** `MacSession+FileDownload.swift:74,81`,
   `FileDownloadWindow.swift:21-37`. A negative offset traps, duplicate or out of order chunks complete a file with holes,
   `totalBytes` is never checked against the cap or free disk, a name of `..` is accepted and there is no stall timer. Fix:
   validate offsets and sizes, reject `.` and `..`, add a 30 s stall timer.
7. **MEDIUM. SSH.** `SSHSession.swift:~237,~437-455`, `SSHModel+HostKeyPrompt.swift:9-22`. SFTP work blocks the loop that
   handles keystrokes, `SSHClient.connect` has no timeout, and the host key prompt uses one continuation slot, so a second
   prompt or a closed tab leaves a connection hung. Fix: per request timeouts, a 15 s connect timeout, a queue of prompts
   that all resume with false on close.
8. **MEDIUM. Push registration is tried once per launch and never retried.** `SessionNotifier.swift:26-66`,
   `SessionModel+PushToken.swift`. A failure is stored as text, permission granted later does nothing until relaunch, and the
   token is sent to the Mac with no acknowledgement. Fix: register on every `.active` while authorised, retry with backoff.
9. **MEDIUM. Agent approvals report "delivered" with no acknowledgement.** `AgentApprovalResponder.swift:20-65`,
   `MacSession+Agent.swift:122-127`. If the link drops in the window, the Allow is lost, the banner is gone and the agent
   waits forever. Fix: retract only when the Mac confirms, otherwise post a delivery failure.
10. **LOW-MEDIUM. Memory warnings and Low Power Mode are not handled.** Terminal buffers, logs and transcripts are never
    trimmed and streaming runs at full rate. Fix: observe both notifications, trim buffers, lower quality.
11. **LOW-MEDIUM. URL commands run without confirmation, and while the app lock is up.** `MacCastApp.swift:126-186`,
    `AppSecurity.swift:86-88`. Any page or app can open `peering://disconnect` or `peering://end-shells`, and `connect` spends
    relay allowance. Fix: confirm destructive links, ignore `connect` while locked.
12. **LOW.** Product fetch has no retry (`StoreManager.swift:301-320`), `Transaction.updates` task never cancelled, wall
    clock used for the 30 s and 1 min windows, direct path discovery opens a new relay socket every minute, unbounded preview
    event stream, `isNumber` accepts non ASCII digits in the pairing code check, unbounded host name and MAC address
    persistence, SSH events keep only the newest 1024.

Present and well done: relay splice back pressure and the 16 MB frame cap, pin and handshake discipline (fail closed,
commit and reveal SAS, pin stored only after confirmation), the loopback only preview proxy policy.

## Mac host

1. **HIGH. Pairing approval is not tied to a session.** `HostServer.swift:167`, `HostModel+Events.swift:100-106`. Any LAN
   client that sends a confirm with no proof reaches awaiting approval, and when the user clicks Allow for their own phone,
   every waiting session is pinned, the attacker included. A second pairing overwrites the first prompt. Fix: carry the
   session id in the event and the resolve call, allow one unauthenticated pairing at a time.
2. **HIGH. No restart after a mid session capture stop or encoder failure.** `CaptureEngine.swift:312`,
   `CapturePipeline+Frames.swift:103`, `VideoEncoder.swift:338`, `HostModel+Lifecycle.swift:88`. After sleep, wake, lid close
   or a display change the stream is dead and the phone stays attached to a frozen picture, and a dead encoder session logs a
   failure on every frame (about 60 per second). Fix: rebuild with capped backoff and a retry limit, rate limit the log.
3. **HIGH. The relay signalling socket has no liveness watchdog and no network or wake awareness.**
   `RelayHostRegistration.swift:165-170`, no `NWPathMonitor` or sleep and wake observers anywhere. After wake or a network
   change the socket is half open, the host shows Registered and remote phones see offline for minutes. Fix: track pongs,
   re-register after about 2 missed pings, observe wake and path changes.
4. **HIGH-MEDIUM. The reconnect loop resets its backoff too early and has no jitter.** `RelayHostRegistration.swift:139-178`.
   A relay that accepts then drops the registration gives a 1 s loop forever, and every host retries on the same schedule
   after a relay restart. Fix: reset only after about 60 s up, add 20 to 50 percent jitter.
5. **MEDIUM-HIGH. A relay tunnel is matched to a connection by arrival order with no timeout.** `HostServer.swift:353,475`.
   A tunnel that never completes mislabels the next direct LAN connection as relayed, gives it video on the control stream and
   cancels a bridge it does not own. Fix: match by source port or a nonce, expire after about 10 s.
6. **MEDIUM. No cap on unauthenticated connections and no file descriptor limit raise.** `HostServer.swift:352,320`. The soft
   limit is 256 and a pre-auth peer may buffer a 16 MiB declared frame. Fix: cap pre-auth sessions (about 8 total, 2 per
   address), a small decoder cap before ready, raise `RLIMIT_NOFILE`.
7. **MEDIUM. No outbound back pressure for control stream senders.** `PeerConnection.swift:44`,
   `TerminalSessionManager+Shells.swift:141`. A backgrounded phone gets 180 s of silence and only video is paused, so output
   from `yes` or an agent queues without limit. Fix: count bytes in flight, coalesce or drop above about 4 MB, stop PTY reads
   while backed up, pause terminal and agent forwarding while the client is backgrounded.
8. **MEDIUM. Upload disk writes have no back pressure and staging files are orphaned.**
   `TerminalSessionManager+FileTransfer.swift:80,143`. A second begin on the same path leaks the handle and the `.part` file,
   and crashes leave `.peering-*.part` files. Fix: gate on queued bytes, discard on replace, idle timeout, sweep.
9. **MEDIUM. Hung children and unbounded output in the process runners.** `AgentCommand.swift:24-28`,
   `AgentGitRunner.swift:60-80`. The timeout kills only the direct child, grandchildren hold the pipe open, output has no cap
   and zips can fill the disk. Fix: process groups and group kill, cap output, check free space.
10. **MEDIUM. The pin store treats any read failure as empty, same as the iPhone.** `PeerPinning.swift:60,93-99`. A locked
    keychain at login launch makes the first pairing erase every other phone's pin. Fix: as the iPhone.
11. **MEDIUM. Stopping an agent CLI leaves grandchildren running.** `AgentProcess.swift:81`. Fix: own process group, `killpg`.
12. **MEDIUM. Concurrent `agents` probes are unthrottled.** `TerminalSessionManager.swift:68,103`. Each starts a login shell.
    Fix: coalesce into one probe and cache for about 60 s.
13. **MEDIUM. Clipboard handlers block the network queue.** `HostModel+Lifecycle.swift:269,273` use `DispatchQueue.main.sync`.
    While the main thread is busy every session, ping and the reaper stall. Fix: async with a reply.
14. **LOW.** Notification queue has no TTL, dedup or token pruning (`RelayHostRegistration.swift:25,54`), exited terminals
    stay in memory, archive temp copies are swept late, the hook installer treats an unreadable `settings.json` as empty,
    `unpairAll` can leave memory and keychain disagreeing, pause state is keyed by public key so two routes share it, no global
    cap on concurrent transfers or hung network mounts, Sparkle Restart does not warn about a live session. Also:
    `releaseAll()` runs only when the last client leaves, so a button held by a departing client while another stays is not
    released, and `textInput` and `lockScreen` have no rate limit.

Present and well done: video send is latest wins with one frame in flight, the sleep prevention safety net (crash marker,
launch time undo, battery watchdog), the hook socket and approval handling.

## Android

1. **HIGH. Relay signalling can hang forever and half dead sockets are never detected.** `OkHttpSignalling.kt:40-46`,
   `RelayConnect.kt:96-110`, `ReferralClient.kt:40-48`, `ResilientSignalling.kt:31-46`. There is no timeout, no ping and the
   exchange mutex is held throughout. After a Wi-Fi to cellular switch the cached socket is dead, the dial never returns and
   the reconnect ladder never advances. Fix: `withTimeout` of about 10 s, OkHttp `pingInterval` of about 20 s, reset the
   signalling on a network change.
2. **HIGH. A discovery failure crashes the process.** `RouteOpener.kt:21-78`, `LanHandover.kt:13`, `SessionController.kt:214`,
   `NsdDiscovery.kt:63`, `PeeringApplication.kt:27`. `onStartDiscoveryFailed` throws outside the guarded section, with no
   `CoroutineExceptionHandler` on the app scope. NSD failures are common on Samsung or with Wi-Fi off. Fix: put discovery
   inside `guarded`, wrap the handover launch, add an exception handler.
3. **HIGH. Decoder failures kill the link and reconnect into the same failure.** `CodecDecoder.kt:26-85`,
   `VideoPictureRouter.kt:21-23`. Configure and start are unguarded, a failed configure leaks the codec, release can skip
   releasing, and peer supplied sizes are uncapped. The host resends the same config and the loop repeats. Fix: catch
   Exception, release in finally, recreate on a fatal codec error, cap dimensions, show a picture failed state.
4. **MEDIUM. The reconnect window resets only on a picture.** `SessionController.kt:254`, `ReconnectSupervisor.kt:26-43`. With
   video paused or backgrounded, a later drop more than 30 s on fails at once. Fix: also reset when a link reaches Ready.
5. **MEDIUM. A reconnect after a network change redials a stale address.** `ConnectTarget.Paired.discovered`,
   `RouteOpener.kt:26`, `DialPlanner.kt:26-28`. Each rung can wait 10 s on the old address. Fix: re-resolve on reconnect.
6. **MEDIUM. `networkChanged` does not cancel an in flight dial.** `SessionController.kt:211-220`, `ControlSockets.kt:48`,
   `NetworkChangeMapper.kt:39`. Wi-Fi to Wi-Fi moves are ignored and the first event is dropped even when starting offline.
   Fix: cancel and restart the dial on a move.
7. **MEDIUM. `requestSession` is retried on IOException, and the reported failure can be the wrong one.**
   `ResilientSignalling.kt:40-44`, `RouteRace.kt:56-59`. A resend after a drop creates a second relay session, and a quota
   refusal can be hidden behind a LAN timeout so the ladder re-asks the relay up to 6 times. Fix: no auto retry of non
   idempotent requests, prefer terminal failures.
8. **MEDIUM. An upload hangs when the link drops.** `FileBrowser.kt:117`, `SessionFileBrowsing.kt:74-80`. Later uploads block
   and the host keeps a partial file. A revoked file grant can crash the app scope. Fix: end uploads on Lost, add a timeout.
9. **MEDIUM. The download write queue is unbounded** (`SessionDownloads.kt:45-47`, 512 MB cap), so a slow provider can run
   out of memory. Fix: bound the queue with back pressure.
10. **MEDIUM. Preview bodies are unbounded.** `PreviewProxyClient.kt:41,49`. Fix: cap total bytes per response.
11. **MEDIUM. The whole session runs on the Main thread.** `PeeringApplication.kt:27`, `ReaderLoop.kt:25-31`. A 16 MiB frame
    decode, JSON parsing and video reassembly run on Main, which causes jank and ANRs. Fix: collect on Default.
12. **MEDIUM. No foreground service and a tight silence limit.** `AndroidManifest.xml`, `ConnectedLink.kt:252` (3 s). In
    Doze or the background the link is lost and nothing retries on foreground. Fix: document it or use a foreground service,
    relax the limit while backgrounded, retry on foreground.
13. **MEDIUM. A keystore read failure is treated as no data.** `KeystoreBlobStore.kt:27-41`, `PinStoreImpl.kt:13`,
    `KeystoreIdentity.kt:50-108`. All pairings can vanish, a new client id is minted, and an unchecked provider exception
    escapes. Fix: distinguish absent from unreadable, do not overwrite, catch RuntimeException, tell the user.
14. **MEDIUM. Image decoding has no size limits.** `ClipboardImages.kt:26-41`, `ImageBitmapDecoder.kt:9-10`. OutOfMemoryError
    is an Error and kills the app, shared files are named by a 32 bit hash and never pruned. Fix: check size, `inSampleSize`,
    SHA-256 names, prune.
15. **LOW.** Peer supplied terminal sizes are unclamped (`TerminalSessions.kt`), the multicast lock is shared with a non
    reference counted lock (`MulticastLease.kt:7`), NSD resolve has no timeout (`NsdDiscovery.kt:115-125`), `RouteRace` can leak
    an open transport (`RouteRace.kt:61`), widget publisher loops die on unexpected exceptions (`WidgetPublisher.kt:97-103`),
    startup failures are unchecked (`followMoves`, `createClientId`) and several settings writes use `apply()`, the client hello
    is sent before the pin check because TLS always dials with `pin = null` (`ControlSockets.kt:37,53`), FLAG_SECURE applies only
    when the app lock is enabled so the remote screen shows in recents otherwise (`MainActivity.kt:87`).

Present and well done: pin enforcement and rollback on failed writes, entry point hardening for widget links, peer length
caps (16 MiB frames, 64 KiB control payloads, bounded reassembly, clipboard image budget, capped transcript).

Status of items 11 to 15, 21 and 22 (app, platform storage and handshake):

* 11 partly done. The inbound frame channel is bounded (256 frames, so a reader that gets ahead stops reading and the host
  is held back) and the control stream is cut into frames on `Dispatchers.Default` (`SessionPorts.readerContext`). Still on
  Main, on purpose: `FrameRouter` JSON parsing, video reassembly, the terminal byte parser and the hand over of decoded
  pictures. `ConnectedLink`, `SessionController` and the presenters mutate unsynchronised state that the UI also calls
  into (`link`, command queues, `notice`, `hostPointer`), so collecting on Default would need a threading redesign
  of the session core and cannot be done with no behaviour change.
* 12 done except a foreground service, deliberately not added. Silence limit 30 s while backgrounded, one automatic
  retry on return after a loss, FAQ entry and `android/README.md` section.
* 13 done. Absent and unreadable are different results (`StoredRead`); a pin file or client id that may be readable
  later is never overwritten; the user is told once to pair again. A device that gets a blank storage after a
  permanent key loss still pairs. Pairing and `PinStoreImpl.record` still write synchronously on the caller's thread.
* 14 done. Sizes are checked before reads, decoding is sampled to 16 M pixels, `OutOfMemoryError` is caught at the
  decode boundary, shared files are named by SHA-256 and pruned (one day, 64 MB).
* 15 done: counted multicast lock, widget publisher survives failures and bounds its snapshots, `followMoves`
  tolerates a failing registration, app lock, relay usage, key value and history writes are flushed off Main. Not done:
  the settings, macro and device preference stores still `commit()` on the calling thread because they return the result
  to the user; the NSD resolve timeout and `RouteRace` leak belong to the session core work.
* 21 partly done. The hello cannot wait for the host id: the host answers a hello and sends nothing first, so a
  different order is a protocol change. A dialled host whose pin differs from the key in its certificate now gets no hello
  at all. A first pairing and an undialled address still send the name, which the host shows the person.
* 22 done. `MainActivity` sets FLAG_SECURE whenever a session exists, not only under the app lock (release builds).

## Relay

1. **HIGH. No per IP limit anywhere.** `signalling.rs:395-450`, `tcp_relay.rs:41-60`. Registration is unauthenticated, a single
   host can use the whole 4096 connection cap so real Macs cannot register, and about 3.3 allocations per second against a
   fake host keeps all 1000 sessions alive against the 300 s TTL, so legitimate users get `relayFull`. Fix: per IP caps on
   connections and allocation rate, require a proven host for `ConnectToHost` targets.
2. **HIGH. Push relay with unbounded outbound tasks and no timeouts.** `signalling.rs:587,1011-1030`, `apns.rs:344-356`,
   `fcm/https.rs:53-75`. Any registered host can push arbitrary text to arbitrary tokens through your key, with no rate limit,
   and each push opens a new connection with no timeout, so a hung endpoint exhausts file descriptors and the listeners fail
   too. Fix: timeout, a semaphore, a per connection token bucket, one long lived connection per host.
3. **HIGH. Read and write stalls bypass the idle timeout.** `signalling.rs:529,547`. Both awaits sit inside a `select!` arm so
   the deadline is not polled, a client that stops reading holds a permit forever, and a full channel can self deadlock. Fix:
   `timeout` around both sends, `try_send` for replies.
4. **MEDIUM-HIGH. Apple receipts are bearer tokens, so metering is easy to evade.** `storekit.rs`, `signalling.rs:700-760`. A
   purchased receipt can be copied to any number of devices, and a fresh client id per connection gets a fresh 30 minutes.
   Fix: bind receipts with `appAccountToken`, add a per IP daily relay seconds meter.
5. **MEDIUM. Referral abuse and denial of service.** `referrals.rs`. Self minted keys farm free time, and 100k fake keys fill
   the code table so real users get `referralsBusy`. Fix: gate redemption on a verified identity or an IP quota, do not mint
   codes on `ReferralStatus`.
6. **MEDIUM. Unbounded device binding growth and a host table leak.** `device_bindings.rs:130-170`, `signalling.rs:300-340,
   620-700`. The binding file is never compacted and shares a directory with the usage log, appends run under a std mutex, and
   repeated `RegisterHost` leaks earlier ids and reports false presence. Fix: remove all ids on close, one registration per
   connection, cap entries, compact.
7. **MEDIUM. APNs retry and backoff.** `apns.rs:218-260,336-380`. The other host is retried on any refusal (should be
   `BadDeviceToken` only), 429 and 5xx have no backoff, 403 does not force a token refresh and `410 Unregistered` does not
   drop the token. Fix: parse the reason, add a circuit breaker, refresh the JWT once on 403 and no more often than every 20
   minutes (the current 45 minute refresh is fine).
8. **MEDIUM. Usage log under disk or descriptor pressure.** `quota.rs:297-330,526-600`. `fsync` runs under the global mutex, a
   failed reopen after rename loses all later charges until restart, a failed compaction retries on every append, and a forward
   clock jump writes a future window. Fix: a dedicated writer task, back off on failure, ignore windows more than a day ahead.
9. **MEDIUM-LOW. Unsupervised tasks, shutdown and health.** `main.rs:178-179,209`. A panic in the control, UDP, sweep or stats
   task dies silently while `/healthz` stays 200, the health script restarts the relay every 5 minutes if the optional web
   listener fails to bind, and only `ctrl_c` is handled, not SIGTERM. Fix: join the handles, handle SIGTERM, make health reflect
   the real listeners.
10. **MEDIUM-LOW. Play and FCM network calls.** `play_api.rs:148-200`, `fcm/https.rs`. A 2 s timeout that includes OAuth fails
    closed to Free, the cache is per socket so each reconnect re-queries Google, the token cache has no single flight and the FCM
    client has no timeouts. Fix: a global stale if error cache, a single flight lock, timeouts.
11. **LOW. Deploy and config.** `relay/tools/deploy-relay.sh`, `config.rs:283-380`. A crash looping new binary still shows
    active after `sleep 3`, `.bak-*` binaries accumulate, no start limit, zero durations are accepted, referral days can
    overflow, and a half set APNs config silently disables push. Fix: post deploy health and signalling probe with binary
    rollback, validate durations, `checked_mul`, warn.

Present and well done: pre token and accept hygiene (5 s token deadline, permit semaphore, accept error backoff, monotonic
activity timing immune to clock jumps), offline receipt verification, secrets written atomically.

## Windows host

1. **HIGH. Capture and encoder failure never recover and are never reported.** `peering-platform/src/dda.rs:30-45`,
   `dda/sys.rs:140-150`, `host/src/runtime/video.rs:~215`, `coordinator.rs:261`. A GPU reset, driver update or display mode
   change is classified fatal and the state is terminal until the client re-sends the source, reacquire reuses the removed
   device, the watchdog only fires before the first frame, and `run_pump` swallows pump errors with no log or backoff. Fix: map
   device lost and reset to recreate the device, add a post first frame stall watchdog, rebuild the encoder with backoff.
2. **HIGH. Critical tasks are unsupervised and run on one thread.** `runtime.rs:~270-285`, `video.rs run_pump`. A panic in the
   pump kills video, terminals, commands and snapshot publication while the tray shows the last healthy snapshot, and a hung
   encoder call freezes every connection and the relay ping. Fix: `catch_unwind` per pass or await the handles and report
   stopped, encode off thread with a deadline.
3. **MEDIUM. Relay reconnect behaviour.** `relay.rs:60-110`, `registration.rs:12,131,141`. No jitter, no Pong deadline so a half
   open socket shows Registered after sleep or a network change, and a clock more than 300 s off loops at 30 s showing only
   Retrying. Fix: full jitter, a frame deadline of about twice the ping interval, surface `proofStale`.
4. **MEDIUM-LOW. The paired device list resets on a schema or serde error.** `host/src/runtime/pins.rs decode()` uses
   `unwrap_or_default()`, so a bad document becomes an empty list and the next record overwrites it. Fix: fail with an error and
   keep a `.bad` backup.
5. **LOW.** UI thread and helper failure paths (`reg` and `netsh` by bare name on the UI thread with no timeout, the elevated
   helper result never reaches the UI, `apply_rule` deletes the old rule before adding), stuck keys for up to 120 s on a silent
   drop, and a global pre-auth cap of 32 that a LAN host can fill.

Present and well done: pre token hygiene shared with the relay, receipt handling, DPAPI atomic writes and loud identity load.

## Cross cutting

- **Pin store read failure erases pairings** (iPhone, Mac host, Android, Windows device list). One shared rule: distinguish
  unreadable from absent, never overwrite on unreadable, keep a backup, tell the user.
- **No liveness or timeout on signalling sockets** (iPhone handshake, Mac host relay registration, Android relay exchange,
  Windows relay registration). One shared rule: a deadline on every exchange, ping and pong tracking, re-register after wake
  or a network change, jittered backoff reset only after a stable period.
- **Unbounded queues from a slow peer** (iPhone uploads, Mac host terminal output and uploads, Android downloads and previews,
  relay push tasks). One shared rule: count bytes in flight and apply back pressure.
- **Unauthenticated resource caps** (Mac host, relay, Windows host). One shared rule: per IP and global caps before auth.
- **Capture and decoder recovery** (Mac host, Windows host, Android decoder). One shared rule: recover with capped backoff and
  surface a coded failure to the user.
- **Session ids on approvals and pairing** (Mac host pairing approval, Windows pairing scoped in the earlier round).

## Open items after the relay round

- **Apple receipts are still bearer tokens (relay 4).** The fix is `appAccountToken` bound to the device key when the iPhone app
  starts a purchase, with the relay requiring it to match the proven key (Play already does this). Needs an iPhone client change,
  so only documented in `relay/README.md`.
- **`referralStatus` still issues a code on first ask (relay 5).** Both clients read their own code from that reply. Not minting
  there needs an explicit request message in `apple/RemoteCore` and `android/core/session` first. Mitigated meanwhile by a
  per network daily cap on redemptions and 10000 codes kept for redeemers.
