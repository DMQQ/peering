# Morning checklist

Written 2026-10-13. Everything below is code that is merged on `monorepo` and pushed. All of it passed its tests and
builds here, but none of it has run on a real iPhone, Mac host, Android phone, Windows PC or the live relay. Only you can
check these. Work top to bottom.

What was verified on this Mac (so you can skip re-running it): `apple/Tools/check.sh` passes end to end (catalogs, MacCastKit,
RemoteCore, SSHCore tests, iPhone app and Mac host builds, MacCastProbe and CaptureProbe builds); relay 509 tests; Android
1,989 tests with debug and release builds; Windows 1,221 tests (222 more with the `terminal-hooks` feature) and workspace
clippy clean, and the Windows target compile of the platform and host crates. A full Release archive of the iPhone app does
not build here (the PostHog dSYM step needs `POSTHOG_CLI_API_KEY`), so do that in Xcode.

## 0. Before you submit the iPhone build

- [ ] Ship through TestFlight to your own devices first, not straight to review.
- [ ] Install the new Mac host (Sparkle) and the TestFlight iPhone build together. The phone works with an old host, but
      pairing approval, capture recovery, the background notice and Live Activity cards only act with the new host.
- [ ] Make a real Release archive in Xcode and confirm the dSYMs upload.
- [ ] App Store Connect, App Privacy: add Diagnostics, then Other Diagnostic Data, NOT linked to the user, NOT used for
      tracking, purpose Analytics. Keep the existing answers (Product Interaction, Device ID, Crash Data).
      `PrivacyInfo.xcprivacy` already declares it.
- [ ] Do NOT deploy the relay before the TestFlight run (section 6). The new phone works without it, with the old paywall
      estimate.
- [ ] Rebuilding or reinstalling the Mac host while it runs revokes its Screen Recording permission: install the signed
      build the normal way and re-grant if asked.

## 1. iPhone with the new Mac host

Live Activities and notifications (host driven):
- [ ] Start a session, background the app, watch the Lock Screen card keep updating (driven by the Mac through the relay).
      This needs the relay deployed to be fully live: before that, expect no pushed updates.
- [ ] Finish an agent task while the phone is locked: the card shows finished, and tapping the CARD BODY (not Open) opens
      that chat, also after the Mac session ended. A finished card should leave the Lock Screen about 30 minutes later.
- [ ] Agent approval while locked: the card shows it and tap opens the chat. iOS 17.2 or later with the app killed: a
      card should appear by itself (push to start).
- [ ] Look for double banners (notification plus activity alert for one event) and tell me which events.
- [ ] The session timer on the card must read right (pushed dates are seconds since 2001; a 1970 or 2057 time is a bug).
- [ ] Notifications while the app is backgrounded but still connected.

Background notice:
- [ ] LAN session, lock the phone for 2 to 3 minutes, unlock: picture returns without a reconnect loop. Repeat on the iPad.
- [ ] Open Control Center, a Face ID prompt and the app switcher during a session: the Mac's video must NOT pause (only
      the real background does).
- [ ] Picture in Picture: leave the app with PiP on, video keeps playing.

Failures, limits and safety:
- [ ] Paste more than 48 KB into the clipboard push, a terminal and an agent prompt: clear message, session stays up. Try
      text full of quotes, slashes and newlines.
- [ ] Pair a second Mac: the first stays paired (pin store fix).
- [ ] Put the Mac to sleep mid session and wake it: capture comes back by itself.
- [ ] Three drops in a row (airplane mode toggles): it stops retrying and shows "Connection keeps dropping..." with a
      manual reconnect button.
- [ ] Large file upload on a slow link: memory stays flat, the new cancel button works. SSH host that does not answer:
      connect times out and closing the tab cancels it. SSH host key prompt queue.
- [ ] `peering://disconnect` and `peering://end-shells` from Safari while a session is live: it asks first. While the app
      lock is showing nothing runs, and a pending confirm cannot be accepted behind the lock.
- [ ] A Mac whose key changed: the phone says the identity changed, to continue only if you expect it, and offers
      forgetting and pairing again (before: silent retries). Read the wording yourself, it is security critical.
- [ ] Low Power Mode on: quality drops one tier and fps is capped at 30; turning it off lifts both.
- [ ] Memory warning (Xcode Debug, Simulate Memory Warning): terminal buffers and transcripts trim.
- [ ] Damaged pairings: this state is hard to produce. If the Connect screen ever shows "Damaged pairings", the Settings
      "Reset paired Macs" action must clear it and let you pair again.
- [ ] With the OLD relay (today's): no false "quota exhausted" paywall after a short relay session. After the relay is
      deployed: relay minutes left on the Activity tab match the journal's `remaining_secs`.

## 2. Mac host (new build) things only a real Mac can show

- [ ] Menu bar: the dropdown opens CENTRED under the icon with an arrow, the icon is centred in the button, the dot colour
      follows state (setup orange, stopped red, waiting grey, ready blue, streaming green), clicking again, outside or
      Escape closes it, text fields in the popover take focus, Open Peering works with the main window open, closed and
      minimised, VoiceOver reads "Peering", with a second screen it appears on the icon's screen, Cmd-drag position
      persists (autosave name changed, it may land at the default once), "Check for Updates" still works.
- [ ] Stop hosting while a phone's Live Activity is up: the card ends, the UI does not freeze, the relay link drops only
      afterwards. Quit while hosting: it waits up to 1.5 s. Stop then start within 1.5 s: briefly two relay registrations
      (check the relay tolerates it).
- [ ] `kill` a long running agent: the whole process group dies after the grace.
- [ ] A throttled phone link: agent chat events and terminal output resume in order after it drains.
- [ ] Capture after sleep, wake, lid close, display change: it restarts (schedule 1, 2, 4, 8, 16, 30 s, six tries) and
      the phone shows a notice if it gives up.
- [ ] Low Power Mode on the phone: the Mac's capture and encode CPU should drop (the stream's own frame interval is
      lowered). If the picture glitches when the rate changes, tell me: it falls back to dropping frames at ingest.
- [ ] Pairing with a second device waiting on the network: clicking Allow only pins your phone.
- [ ] Host Activity feed: switch the Mac to another language, entries show in it; copied logs stay English.

## 3. Languages

The apps ship en, de, es, fr, it, ja, ko, pt-BR, ru, zh-Hans. `python3 apple/Tools/check-localization.py` passes (it is now
a step in `apple/Tools/check.sh`).
- [ ] Switch a device to German, Japanese and Russian and open the new messages: connection keeps dropping, paste too
      large, identity changed, damaged pairings and reset, upload cancelled, close all shells, end this session,
      approval and finished cards, capture recovery notice. Look for English leftovers and clipped text.
- [ ] Have a native speaker read the list in `docs/reviews/localization-audit.md` ("native speaker review"): Russian
      and Korean wording first, then Japanese, and the security sentences (identity changed, no pairing on file).
- [ ] Pushes composed on the Mac (agent finished, terminal needs you, Live Activity alerts) follow the MAC's language, not
      the phone's. That is a known limit.

## 4. Android (phone was unplugged)

Install the release APK (`android/tools/README.md`), then:
- [ ] Network change: start a relay session, join the home Wi-Fi, it should move to LAN. Wi-Fi to Wi-Fi counts too.
- [ ] Background and return: with "Keep sessions in the background" on, the session stays up behind the ongoing
      notification and the Mac pauses the picture; with it off the session may end after 30 s away and returning retries
      once and pings the host at once after a network move.
- [ ] Background service and notices (Android): screen off for several minutes, over Wi-Fi and over the relay; the
      notification's Disconnect and tap; Allow/Deny from the lock screen (Allow asks to unlock); a terminal password
      prompt; an agent finishing; notices vanish on return; denying POST_NOTIFICATIONS leaves the session working; try an
      aggressive OEM battery setting (Xiaomi, Samsung, OnePlus) and see whether the service survives.
- [ ] Widgets (Quick Connect and Agents): add both, tap to connect and open an agent. A tap needs the per-install nonce
      (a forged link from another app is ignored); with the app lock on a tap waits for unlock.
- [ ] Invites in Settings: expect an error until the relay is redeployed (the live relay does not know `referralStatus`).
      After deploy: each relay refusal shows its own message.
- [ ] Web preview, mosaic editing, saved prompts, attach files, changes review, folder picker for new terminal, Connect flow,
      pairing and the joystick (large refactors there: these are the riskiest for behaviour).
- [ ] A cloud or SAF download that fails mid way must show "destination failed", not crash.
- [ ] `adb shell svc power stayon false` (I left stay-awake on during testing).

## 5. Windows

- [ ] GitHub Actions, the `windows` workflow: the first real compile of the host. Fix whatever it reports. Push a tag like
      `windows-v0.1.0` to test the release workflow (`windows-release.yml`; the installer version comes from the tag).
- [ ] Nothing in the Windows host has ever run on Windows. Items only compiled by reading: D3D device recreation,
      abandoning a hung encode, DPAPI install entropy and re-seal, ACLs, firewall helper, reset paired devices button.
- [ ] The Windows host truncates file listings to what fits a 64 KiB frame (about 450 entries) and sets `truncated`; the Mac
      sends up to 2000 in one frame.
- [ ] A truly wedged GPU driver call leaks one thread until restart (documented in `windows/README.md`).

## 6. Relay deploy (not before the TestFlight run)

1. `cd relay && cargo test --locked`.
2. Check nginx on the box still matches: it must set `X-Real-IP $remote_addr` and use `set_real_ip_from` Cloudflare ranges
   with `real_ip_header CF-Connecting-IP` (I read your live config: it does). The relay now trusts ONLY `X-Real-IP` by
   default (`PEERINGD_CLIENT_IP_HEADER`); a forged `CF-Connecting-IP` or `X-Forwarded-For` is ignored.
3. Optional env: `PEERINGD_CONTROL_IDLE_SECONDS` (default 45, 0 disables), `PEERINGD_HEALTH_PORTS`, per-IP limits
   (`PEERINGD_MAX_SIGNALLING_PER_IP`, `PEERINGD_MAX_CONTROL_PER_IP`, `PEERINGD_SESSIONS_PER_IP_PER_MINUTE`,
   `PEERINGD_MAX_UNSPLICED_PER_IP`). All documented in `relay/README.md`.
4. `relay/tools/deploy-relay.sh` (restarts the service briefly; it checks `/healthz` and the signalling and control ports
   and rolls the binary back if they do not answer; keeps the newest five `.bak-*`).
5. Watch the journal: the 10 minute `relay summary since the last one` line, `end_reason`, `video_path`, and refusal
   counters (the README has six `journalctl` one-liners, including "is UDP video failing").
6. Then re-test: the paywall, Live Activity push and push to start, invites, a stalled control channel ending after 45 s.
- Unverified against Apple (never sent for real): the exact push to start rules, whether `apns-expiration` equal to the stale
  date is accepted, and the reason strings for dead activity tokens.
- Known relay gaps: Apple receipts are bearer tokens (bind with `appAccountToken`, needs a phone change); `referralStatus`
  still mints a code on first ask (mitigated by a per-network cap of 5 a day and 10,000 reserved codes); requiring a proven
  host for `ConnectToHost` is built but OFF by default (turn on with `PEERINGD_REQUIRE_PROVEN_HOSTS` once the fleet updated).

## 7. Reading PostHog after the new builds are live

- [ ] `session_started` on the phone and `host_session_started` on the Mac carry the same `session_ref`; the three queries in
      `docs/analytics-events.md` ("How to investigate a failure") return rows.
- [ ] Filter your own devices with `internal_build`.
- [ ] Android and Windows send no analytics (decided: later).

## Open items I could not or did not do

- Android: the session core still parses on the Main thread (needs a threading redesign); a micro benchmark guards the
  per frame cost.
- Android follow-up: push when the app is fully closed (FCM through the relay: the host's push to a registered token
  with the approval and finished categories, as for the iPhone's APNs), and Reply/Continue buttons on the finished
  notice. Terminal "command finished" notices need the host to send a finished event the wire does not carry yet.
- Windows: terminal and agent snapshot sizes are not capped.
- Receipts bound to the device (`appAccountToken`), see section 6.
- An older branch `worktree-agent-a88300f4d9d3cd81e` (two plans with Lifetime, 4 Oct) is unmerged and not part of this work.
- The `appStoreReceiptURL` deprecation warning in `apple/MacCast/App/Analytics.swift` remains (it detects TestFlight; moving to
  `AppTransaction` is async).
- Disk: agent worktrees under `.claude/worktrees` use space; `git worktree remove` the ones you no longer need (the merged
  ones are already removed except three locked ones and the unmerged branch above).
