# Peering: plans, features and placement

Written 18 September 2026. Self-contained on purpose — move it wherever it belongs.

**Status key:** ✅ shipped · 🔧 in flight · ❌ not started

---

## 1. Where the plans stand

| | Free | Relay | Relay Plus | Pro |
|---|---|---|---|---|
| Price | £0 | **£3.99/mo** | **£6.99/mo** | **£24.99/yr** |
| **Decided by the owner** | 30 min relay/day · 1 Mac · terminals with **one shell at a time** | 3 h/day | unlimited relay | unlimited, every Mac, power tools |
| **Still proposed by me, not settled** | — | features identical to free | terminals get tabs, widgets, audio, PiP, more Macs | macros, snippets, privacy mode |

Prices here are the UK storefront. The **live prices are set in App Store Connect** and have not moved yet — `Config/Products.storekit` (the local test config) has them, the published site still shows $4.99 / $14.99 / $79.99.

**The shape in one sentence:** *Relay = more time, Plus = more things, Pro = no limits and every Mac.*

---

## 2. Every feature the app has, and where it goes

### Connection

| Feature | Free | Relay | Plus | Pro |
|---|---|---|---|---|
| Pair once with a six-digit code (device certificates, no account) | ✅ | ✅ | ✅ | ✅ |
| Nearby discovery (Bonjour), connect by address | ✅ | ✅ | ✅ | ✅ |
| Trusted Macs list: rename, forget, choose LAN or relay | ✅ | ✅ | ✅ | ✅ |
| Local network sessions, unlimited and unmetered | ✅ | ✅ | ✅ | ✅ |
| Relay sessions | 30 min/day | 3 h/day | unlimited | unlimited |
| Paired Macs | 1 | 1 | 3 | every |
| Wake on LAN | ✅ | ✅ | ✅ | ✅ |
| Face ID lock on launch | ✅ | ✅ | ✅ | ✅ |
| Siri / Shortcuts: connect, end shells | ✅ | ✅ | ✅ | ✅ |

### Picture

| Feature | Free | Relay | Plus | Pro |
|---|---|---|---|---|
| Share a whole display | ✅ | ✅ | ✅ | ✅ |
| Share one running app, or a single window | ✅ | ✅ | ✅ | ✅ |
| Every Space / desktop as a picture (desktops panel) | ✅ | ✅ | ✅ | ✅ |
| Adaptive quality, fit vs fill | ✅ | ✅ | ✅ | ✅ |
| Session audio (hear the Mac) | ✅ | ✅ | ✅ | ✅ |
| Picture in Picture | ✅ | ✅ | ✅ | ✅ |
| Privacy mode (dims the Mac's displays) | ✅ | ✅ | ✅ | ✅ |
| Screenshot with the system share sheet | ✅ | ✅ | ✅ | ✅ |

**Note:** I put the whole Picture column at free deliberately. App-and-window sharing is
the thing VNC clients cannot do, so it should be what a free user shows somebody else, and
audio/PiP are "does it feel finished" features rather than depth. If any row here moves up,
`Privacy mode` is the one I would gate — it is a power feature and costs nothing to run.

### Control

| Feature | Free | Relay | Plus | Pro |
|---|---|---|---|---|
| Pointer (tap where you look) and relative pointer (joystick/trackpad) | ✅ | ✅ | ✅ | ✅ |
| Scroll wheel | ✅ | ✅ | ✅ | ✅ |
| On-screen keyboard, hardware keyboard, modifier lock keys | ✅ | ✅ | ✅ | ✅ |
| Control mode vs Observe mode | ✅ | ✅ | ✅ | ✅ |
| Clipboard: pull from the Mac, and clipboard history | ✅ | ✅ | ✅ | ✅ |
| Quick commands / snippets (chips above the keyboard) | ✅ | ✅ | ✅ | ✅ |
| Custom macros (editor, save, fire) | ✅ | ✅ | ✅ | ✅ |

**Note:** the two rows I would move up: **macros** and **quick commands** to Pro. They are the
only genuinely "power user" controls, and they are the kind of thing a professional will pay
for without a free user ever noticing they are missing.

### Terminals and files

| Feature | Free | Relay | Plus | Pro |
|---|---|---|---|---|
| Mac terminal (a shell on your Mac, in the session) | ✅ | ✅ | ✅ | ✅ |
| SSH servers: saved hosts, passwords in Keychain, host-key prompt | ✅ | ✅ | ✅ | ✅ |
| Multiple shells open as tabs | **one at a time** | **one at a time** | tabs | tabs |
| File browser on the Mac terminal (navigate, cd, preview) | ✅ | ✅ | ✅ | ✅ |
| File browser over SSH (SFTP, with an exec fallback) | ✅ | ✅ | ✅ | ✅ |
| Upload / download files | ❌ | ❌ | ❌ | ❌ |

**Owner's call, adopted:** terminals are free with **one active shell at a time**; extra tabs
are paid. That is a *concurrency* gate rather than a capability gate — it is the sort of limit
that costs the service something and reads as fair, where hiding the terminal entirely would
read as stingy. Same shape could be reused elsewhere if more gates are needed.

### Around the app

| Feature | Free | Relay | Plus | Pro |
|---|---|---|---|---|
| Live Activity (Lock Screen, Dynamic Island) | ✅ | ✅ | ✅ | ✅ |
| Home Screen widget, Lock Screen widget | ✅ | ✅ | ✅ | ✅ |
| macOS host widget (start/stop the host) | ✅ | ✅ | ✅ | ✅ |
| Session history (last 30 sessions, duration, path, bytes) | ✅ | ✅ | ✅ | ✅ |
| "Your Mac is waiting" / unlock notifications | ✅ | ✅ | ✅ | ✅ |

**Note:** widgets and the Live Activity are the most natural paid rows in this whole document —
they are pure polish, nobody needs them to use the app, and they are visible to other people
(which is free advertising). If more paid differentiation is needed, move these to Plus first.

---

## 3. How gates would actually be enforced

- **Relay minutes** — the relay already meters per device ID per 24 h window. It now needs to
  know the plan; that is being added as a client-asserted field in the relay handshake (see §5).
- **Number of Macs** — client-side, at pairing time. Count `pins.hostIDs`, refuse the pairing
  over the limit, offer the upgrade.
- **Number of terminal tabs** — client-side, at "new shell". Count open shells, refuse above the
  limit. This one is already a natural check: `SSHModel.openShells` and the Mac terminal list.
- **Everything else** — a check at the feature's entry point, against one plan value the app
  reads from one place. The app is currently gaining that single value as `RelayPlan`.
- **Client-side means bypassable.** A patched app can claim anything. That is the same trust
  level as the relay's plan field, and it is the right trade at this size. The real fix, when it
  matters, is verifying Apple's signed transaction offline (see §5).

**How a locked feature should appear:** visible, with a lock, and one tap to the paywall. Never
hidden. A feature a user cannot see cannot make them want it, and hiding the terminal from a
free user just means they never learn it exists.

---

## 4. What is built, in flight, and not started

**Built and running** ✅
- Local + relay sessions, pairing, trusted Macs, wake on LAN, Face ID
- Display / app / window sources, desktops, adaptive quality
- Clipboard + history, macros, quick commands, session audio, PiP, privacy mode, screenshots
- Mac terminal and SSH terminal, with tabs
- File browser on **both** terminals (phase 1 and 2), including SFTP with an exec fallback
- Live Activity, widgets (iOS + macOS host), session history, Siri intents
- Relay: metering per device per day, three products in one subscription group
- Free tier at 30 min/day, relay copy across app, site, terms

**In flight** 🔧
- **A video "lane" and a fallback** (protocol v12). See the correction in §5 first: the premise I
  gave for this was wrong. What it actually adds is a way for the client to ask the host to move
  video onto the control channel, chunking so a keyframe fits, a rate cap while it is there, and a
  probe of the lane it left. On the direct path that is a genuine fallback from the dedicated
  video socket; on the relay path it is only a rate reduction, because video is already there.
- **Per-plan relay allowances** — the relay learns the plan from the handshake; free 30 min,
  Relay 3 h, Plus/Pro unlimited.

**Not started** ❌
- Feature gating (§2 and §3 above)
- Upload / download (file transfer)
- Verifying App Store purchases on the relay (§5)
- Hole punching (direct connection off-LAN instead of always relaying)
- A second relay

---

## 5. Insights worth keeping

### The economics are not what I first told you
Measured on a real session: **27.2 MB in 3m41s** on the iPhone (≈1 Mbps) and **45 MB in 10 min**
on the Mac (≈0.6 Mbps). That is **0.3–0.5 GB per hour**, not the 3.6 GB I first estimated — I had
taken the encoder's 8 Mbps *target* for the relay tier as if it were the rate used. Divide every
per-hour cost figure I gave you earlier by about eight.

Fixed costs: **$99/yr** Apple Developer + **~£80/yr** (395 zł) for the Mikrus 4.1 VPS = about
**$206/yr to stand still**. At $24.99/yr that is 12–24 Pro subscribers. Mikrus does not meter
transfer at all, so relay bandwidth costs nothing at the margin; its real constraints are the
~7 forwarded ports (so: concurrent relayed sessions) and a shared 1 Gbps link under a fair-use
clause. **The relay meter is a conversion lever, not a cost control.**

### Paying users are currently metered as free — the biggest revenue bug
The relay decides who is paid by checking a key against a server-side list, and **nothing mints a
key that can go on it**: the app generates a random UUID locally. So every real subscriber gets
the free allowance, and `SessionModel+Events.swift` hides it by telling them their subscription is
active and to try again later. At 15 minutes this was invisible; at any tiered allowance it hits
exactly the people who paid.

- **Interim (in flight):** the app declares its plan in the relay handshake and the relay applies
  the matching allowance. Client-asserted, documented as such.
- **Real fix:** StoreKit hands the app a JWS (Apple-signed proof of the transaction, carrying the
  product ID). The relay can verify that offline against Apple's root certificate — no backend of
  yours, no accounts, and it answers "paid?" and "which plan?" at once. Caveat: revocation and
  refunds need Apple's server API, so a refunded user keeps access until the JWS expires.

### Architecture: what the field does, and what to take

**Correction, 18 Sep.** I told you "video is UDP-only, so a UDP-blocking network gets no picture"
— repeatedly, and it was wrong. Video in this app is **TCP everywhere**: a dedicated second TCP
socket on the direct path, and the control channel itself on the relay path. Neither app ever
touches the relay's UDP video path: `videoHost`/`videoPort`/`videoToken` are decoded in
`RelayProtocol.swift` and used nowhere, and the only UDP in either app is the Wake-on-LAN magic
packet. The relay *does* implement a UDP video relay (`Relay/src/udp_relay.rs`, with tests) and
hands per-session ports to both ends — it has simply never been wired up on the client.

So the real picture is the opposite of what I described, and better in one way and worse in another:

- **Better:** a UDP-blocking network is not a problem for video, because video is TCP and rides
  the same connection as everything else. Hotel Wi-Fi works.
- **Worse:** on a relay session, video and input share one TCP stream. That is head-of-line
  blocking, and it is the latency issue this project already chased and recorded as unfixed
  ("video sharing the control stream"). Input queues behind a keyframe.
- **The obvious fix is the relay's own UDP path** — the server half exists and is tested. Wiring
  the client to it takes video off the control channel for relay sessions, which is a latency and
  fairness win. That is the opposite of the "add a TCP fallback" work I asked for.

What the field still says, correctly: every strong product does **direct-first with hole punching,
relay as fallback**, and keeps **both** transports so it can trade quality for reachability. You
have the reachability half (TCP always works) but not the quality half.

- **Take:** hole punching at the rendezvous, and wiring up the relay's UDP video path.
- **Skip:** QUIC (no vendor uses it for media; RustDesk's is off by default; "RDP over QUIC" does
  not exist — Microsoft's UDP transport is RDP Shortpath over URCP with ICE/STUN/TURN),
  multipath redundancy, a relay fleet, a custom codec, and libwebrtc (it would cost you the
  property you advertise: a relay that provably cannot read the session).
- **Rare and worth protecting:** direct-first *and* relay-capable *and* no vendor account. Only
  RustDesk self-hosted and Jump's Cloudless mode match that combination.

### Positioning and the money question
At $3.99/$6.99/$24.99 you are at or below the consumer field (Screens $3.99/mo, $29.99/yr, $179.99
lifetime; Jump $14.99 iOS one-time, $34.99 Mac; Splashtop $5.99/mo; TeamViewer $24.90/mo;
AnyDesk ~$28.90/mo; RustDesk, Chrome Remote Desktop, Apple Screen Sharing, Tailscale Personal: $0).
You cannot undercut $0, so the pitch is not price — it is **no account, and a relay that cannot
read the session**, which is the self-hosting/privacy audience. That audience finds products
through one good post, not through the App Store.

**The real risk is obscurity, not competition.** One post that lands on Hacker News or
r/selfhosted is plausibly the first 500 users. And because the app has no analytics and no crash
reporting — a promise in the privacy policy — a bug report or a review is the only signal you
get. (A "Report an issue" row now exists in Settings, in both the iOS app and the Mac host.)

### Traps that will bite on the next release
- **The relay enforces nothing new until it is redeployed.** The app and site say 30 minutes/day
  and per-plan allowances; the running server has whatever it was started with.
- **The site's prices are stale** ($4.99/$14.99/$79.99) until App Store Connect moves. Do not
  change the site first, or it advertises a price the store will not honour.
- **Video shares the control channel on relay sessions** — head-of-line blocking, input behind
  keyframes. This is the real "feels slow when I'm away from home", and the fix is wiring the
  relay's existing UDP path, not adding a TCP one.
- **One relay, no SLA**, and the host's terms ban "resource-heavy uses that disturb others".

---

## 6. Next steps, roughly in order

1. ~~**Redeploy the relay.**~~ **Done 18 September** — tagged `v0.1.6`, built in CI, deployed with
   `Tools/deploy-relay.sh`, and verified through the public hostname. Two faults came out of it
   that were invisible from outside: the relay had no `PEERINGD_WEB_ROOT`, so it looked for the
   site relative to `/`, and nginx sent *every* request on that hostname to the signalling port,
   so the site had never been routed at all. Neither was a crash — the site was simply never in
   the deployed build. Working note: `PEERINGD_VIDEO_PORTS=30190-30190` on that box is **one
   port**, which is the shared-IPv4 port-forward ceiling showing up in the config. UDP video would
   be capped at a single concurrent session there.
2. **Point an uptime monitor at `https://getpeering.app/healthz`.** One line of configuration,
   and it is the difference between hearing about an outage from a monitor and from a user.
3. **Test the file browser for real.** Nothing in either phase has ever run against a live
   server: enable Remote Login on the Mac or point a shell at a VPS.
4. Implement the gates in §2 against the single plan value.
5. Set the real prices in App Store Connect, then update the site.
6. Wire the relay's UDP video path (see the correction in §5) — the server half is finished.
7. Consider hole punching before a second relay.

**Done since this document was written:** the relay ships a systemd unit and a `/healthz` (both
tested, the endpoint verified running); the Mac host has an "Open at login" setting (it had none,
so a reboot silently ended remote access); and both apps have a "Copy diagnostics" button.

**Done since, and verified:** the relay now verifies the StoreKit transaction instead of trusting
the plan the client claims — the JWS is checked against Apple Root CA - G3, pinned in this
repository, and a verified receipt always wins. The **claimed plan is still believed when no
receipt arrives**, which is deliberate: a shipped app cannot send one, so verification-only would
drop every existing subscriber to 30 minutes a day on deploy day. `PEERINGD_TRUST_CLAIMED_PLANS=0`
closes it, and the removal condition is in the README: deploy, watch `plan_trust="claimed"` in the
logs, then turn the fallback off.
