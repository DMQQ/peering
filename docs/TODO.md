# Morning checklist

Written 2026-10-12 night. Nothing below was run on a real iPhone, Mac host, Android phone, Windows PC or the live
relay: every item is a thing only you can check. Work top to bottom. Sections marked (pending) are filled in as the
last agents finish; the final version is at the bottom of this file under "Added at the end".

## 0. Before you submit the iPhone build

- [ ] Ship the iPhone build through TestFlight to your own devices first, not straight to review.
- [ ] Update the Mac host (Sparkle) and install the TestFlight iPhone build together. The phone works with an old
      host, but many fixes (pairing approval, capture recovery, background notice, Live Activity cards) only act
      with the new host.
- [ ] Do a real Release archive (this machine cannot: the "Upload PostHog dSYMs" step needs `POSTHOG_CLI_API_KEY`,
      so every local Release build exits 65 there). Confirm dSYMs upload.
- [ ] App Store Connect, App Privacy: add Diagnostics, then Other Diagnostic Data, marked NOT linked to the user,
      NOT used for tracking, purpose Analytics. Keep the existing answers (Product Interaction, Device ID, Crash
      Data). The repo's `PrivacyInfo.xcprivacy` already declares it. Details in `docs/analytics-events.md`.
- [ ] After the new phone and Mac host are live, open PostHog and check `session_started` on the phone and
      `host_session_started` on the Mac carry the same `session_ref`. The three queries in
      `docs/analytics-events.md` ("How to investigate a failure") should then return rows.
- [ ] The relay is NOT deployed and must not be today: the new iPhone paywall logic and the Live Activity push work
      without it, but the relay-reported remaining minutes, push to start and the idle timeout need it. Deploy order is
      at the end of this file.

## 1. iPhone and Mac host, with both updated

Live Activities and notifications (host driven, new):
- [ ] Start a session, send the app to the background, watch the Lock Screen card keep updating (it is driven by the
      Mac through the relay, the app is frozen).
- [ ] Finish an agent task while the phone is locked: the card changes to finished, and tapping the CARD BODY (not the
      Open button) opens that chat. This was the reported bug. Also try after the Mac session ended.
- [ ] Trigger an agent approval while locked: the card shows it, tap opens the chat.
- [ ] iOS 17.2 or later: kill the app, make an agent need approval, check a card appears by itself (push to start).
- [ ] Look for double banners (a notification banner plus the activity alert for the same event). If it happens,
      tell me which events.
- [ ] Check the session timer text on the card is right (dates in pushed state are seconds since 2001, the card
      must not show a 1970 or 2057 time).
- [ ] A finished card should leave the Lock Screen after about 30 minutes (needs the relay change, otherwise it stays
      about 4 hours: expected until the relay is deployed).
- [ ] Notifications while the app is backgrounded but still connected (before, only a dropped connection pushed).

Background notice (new):
- [ ] LAN session, lock the phone for 2 to 3 minutes, unlock: the picture comes back without a reconnect loop.
- [ ] Repeat on the iPad, which is where the reconnect flapping was seen.
- [ ] Picture in Picture: leave the app with PiP on, video keeps playing.

Failures and limits (new):
- [ ] Paste more than 64 KB of text into the clipboard push, a terminal and an agent prompt: you get a clear message,
      the session stays up.
- [ ] Pair a second Mac, then check the first Mac is still paired (the pin store fix).
- [ ] Put the Mac to sleep mid session and wake it: capture comes back by itself (capture recovery).
- [ ] Make the connection drop 3 times in a row (airplane mode toggles): after the third it stops retrying and shows
      "Connection keeps dropping..." with the reconnect button.
- [ ] Upload a large file over a slow link: memory stays flat, there is a cancel button.
- [ ] An SSH host that does not answer: connect times out, closing the tab cancels it.
- [ ] Open `peering://disconnect` from Safari while a session is live: it asks first.
- [ ] A Mac whose key changed: the phone says so and asks to pair again (before: silent retries).
- [ ] On the Mac, with another device waiting to pair, click Allow for your own phone: only your phone is pinned.

Paywall:
- [ ] With the OLD relay (today's): confirm no false "quota exhausted" after a short relay session.
- [ ] After the relay is deployed: relay minutes left on the Activity tab match the relay (journal line
      `remaining_secs`).

## 2. Mac host menu bar (pending)

- [ ] The dropdown opens centred under the icon with an arrow pointing at it.
- [ ] Open Peering, click outside, Escape, several screens, light and dark menu bar.

## 3. Languages

The apps ship en, de, es, fr, it, ja, ko, pt-BR, ru, zh-Hans.
- [ ] Switch a device to German, Japanese and Russian: open the new screens and messages (connection keeps
      dropping, paste too large, key changed, approval card, Live Activity text) and look for English leftovers
      and clipped text. The final audit result is under "Added at the end".

## 4. Android (phone was unplugged)

Install the release APK: `cd android && ./gradlew :app:assembleRelease ...` (see tools/README.md), then:
- [ ] Network change handover: start a relay session, join the home Wi-Fi, the session should move to LAN.
- [ ] Background and return: session recovers, no crash.
- [ ] Widgets (Quick Connect, Agents): add both, tap to connect, tap an agent.
- [ ] Invite a friend in Settings: expect an error until the relay is redeployed (the live relay does not know
      `referralStatus`).
- [ ] Web preview, mosaic editing, saved prompts, attach files, changes review, folder picker for new terminal.
- [ ] Lock screen: with the app lock on, a widget tap waits for unlock.
- [ ] Turn off the stay awake setting I left on: `adb shell svc power stayon false`.

## 5. Windows

- [ ] Open GitHub Actions, the `windows` workflow: first real compile of the host. Fix whatever it reports.
- [ ] Nothing in the Windows host has ever run on Windows.

## 6. Relay deploy (not today)

Order: run `cd relay && cargo test --locked`, then `relay/tools/deploy-relay.sh`, then watch the journal for the new
"relay summary" line and check `/healthz`. It restarts the service briefly. Then re-test the paywall, Live Activity
push and invites. Known unverified against Apple: the exact rules for starting an activity by push, whether the
expiration header is accepted, and the reason strings for dead tokens.

## Open items I could not do

- Receipts are bearer tokens: bind Apple receipts to the device with `appAccountToken` (needs a client change).
- Android and Windows send no analytics (decided: later).
- Android has no foreground service, so a session ends in the background.
