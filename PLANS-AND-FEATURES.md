# Peering: plans, features and placement

Written 18 September 2026. Self-contained on purpose — move it wherever it belongs.

**Status key:** ✅ shipped · 🔧 in flight · ❌ not started

---

## 1. Where the plans stand

**Updated on 21 September.** The live ladder is:

| | Free | Relay | Relay Plus | Pro |
|---|---|---|---|---|
| Monthly | $0 | **$2.99** | **$5.99** | **$9.99** |
| Yearly | $0 | **$19.99** | **$44.99** | **$79.99** |
| Relay per 24h | 1 hour | unlimited | unlimited | unlimited |
| Paired Macs | 1 | every | every | every |
| Sound, Picture in Picture | | yes | yes | yes |
| Moving files both ways | | yes | yes | yes |
| Told when a terminal needs you | | yes | yes | yes |
| Several shells at once | | | yes | yes |
| Several Macs at once | | | | yes |
| Macros, snippets, quick commands | | | | yes |
| Several of the Mac's windows in one picture | | | | yes |
| The sharpest picture over the relay | | | | yes |

Several Macs at once is the row that is about how many may be *live* rather than how many may be
paired, and the two are deliberately separate. "Paired Macs" above is a limit on a list and is true
on Relay and up; this one is a limit on concurrency and is Pro. So a Relay subscriber pairs every
Mac they own and holds one at a time, which is what the card for that rung says. One Mac at a time
is free on every plan, and the first one always will be.

The picture row is the newest and the only one in the map about *how much* rather than *whether*.
Automatic quality starts at 20 Mbps on a direct path and 8 on a relay, and climbs; a relayed
session without this stops climbing at 8, and one with it reaches 20. The direct path is uncapped
on every plan, so a free user on their own network sees the same picture they always did.

**Every tier is sold monthly and yearly**, at about eight months of the monthly to the year. That
is the change that mattered most: the ladder used to sell the middle rung monthly and the top one
yearly, so Relay Plus cost $179.88 a year and Pro cost $39.99, and the paywall was comparing two
periods rather than two plans.

**The shape in one sentence:** *Relay is the remote working set, Plus is the clock going away, Pro
is the toolbox and the funder.*

**The gates are built.** Eight `PlanCapability` cases in
`MacCastKit/Sources/MacCastKit/PlanAccess.swift`, each with a `minimumPlan`, and around twenty call
sites in the app that ask one of them. The relay meters relay time against a plan it verifies from
Apple's own receipt rather than from the client's word. Section 2 is the row-by-row account, checked
against the code.

### Where the numbers came from

Measured against the field rather than chosen. Screens 5 is $3.99/mo and $29.99/yr with no
permanent free tier and no audio at all; Splashtop charges $23.99/yr just to leave the LAN and
$99/yr for its Pro tier; RealVNC Essentials is $8.25/mo; Astropad Workbench, the closest product to
this one, gives 20 minutes a day free and charges $99.99/yr. Pro at $99.99/yr sits level with
Astropad and below Splashtop Pro. The free allowance here is one hour a day. That is deliberately
long enough for a real session rather than only a demo; the paid plans sell unlimited relay and
the working features around it rather than a slightly larger clock.

### What moved, and why

- **The free relay allowance is one hour.** It covers a real session and still leaves a clear
  reason to subscribe for regular remote work. Paid plans remove the clock entirely.

- **Sound, Picture in Picture, moving files and the Mac count moved down to the entry rung.** The
  entry rung used to differ from free mainly by a larger allowance, which made it the hardest thing
  on the ladder to sell. These four are what the field charges for:
  file transfer is the single most consistent paywall in remote desktop, audio is off entirely on
  TeamViewer's free tier and Performance-tier at Splashtop, and device count is the field's
  favourite axis.
- **Privacy mode, widgets and Live Activity moved down to free.** Nobody in the field gates widgets
  or Siri, Jump includes privacy mode in its free plan, Screens ships Curtain Mode and Apple's own
  ARD has it. Gating them cost enforcement work (the widget extension cannot read StoreKit) and
  bought nothing.
- **Wake on LAN stayed free**, against the field, because it is the one gate that would contradict
  the free tier's own headline: the packet only goes out on the local network, and on your own
  network this app is meant to be complete.
- **Terminal tabs and SSH servers stayed on Relay Plus.** This is the one row that goes against the
  direction of travel in the terminal category, where tabs are table stakes free at Termius, Moshi
  and Prompt. The compromise is that one shell is free and only the concurrency is paid, which
  reads as fair where hiding the terminal would read as stingy.

  **Half of this was reversed on 20 September and the other half was not.** SSH servers are free on
  every plan: the owner's question was "why block SSH for free", and the answer on inspection was
  that nothing about it costs the service anything, because the connection is between the user's own
  phone and their own machine. What looked like a feature was a *list* (hosts the user typed in and
  named and put in their own Keychain) sold back to them, which is the one shape of gate that reads
  as a hostage rather than as a price. **Tabs stayed on Relay Plus**, because a second shell at the
  same time costs a login on the far end and is the concurrency limit the free tier is supposed to
  have. The row above is now "Several shells at once" and carries that on its own.

## 2. Every feature the app has, and where it goes

**Checked against the code on 20 September 2026, and this section now says what the code does.**
The authority is `MacCastKit/Sources/MacCastKit/PlanAccess.swift`: ten `PlanCapability` cases,
each with a `minimumPlan`, and every gate in the app asks one of them. Nothing in the app names a
plan by hand: the cards, the badges and the lock messages all read `capability.minimumPlan.name`, so
there is one list and no second place to drift from.

**Those nine are the whole of what a plan decides.**

| Gated feature | Capability | Cheapest plan |
|---|---|---|
| Pairing another Mac | `extraMacs` | Relay |
| Sound from the Mac | `macSound` | Relay |
| Picture in Picture | `pictureInPicture` | Relay |
| Moving files between the phone and the Mac | `fileTransfer` | Relay |
| The clipboard history | `clipboardHistory` | Relay |
| Being told when a terminal needs you | `terminalAlerts` | Relay |
| Several shells at once, as tabs | `shellTabs` | Relay Plus |
| Several Macs open at once | `concurrentSessions` | Pro |
| Macros, snippets and quick commands (making them) | `macros` | Pro |
| Several of the Mac's windows in one picture | `mosaic` | Pro |
| The sharpest picture over the relay | `highBitrate` | Pro |

**Everything else is free on every plan**, and the tables below say so row by row. Two of those
free rows are free deliberately against the field, and both are argued in section 1: SSH servers,
because the connection is between the user's own phone and their own machine and charging for a
list of hosts the user typed in reads as a hostage rather than as a price; and Wake on LAN, because
the packet only goes out on the local network, and on your own network this app is meant to be
complete.

Two gates are about *how much* rather than *whether*: relay time, which the relay meters per device
per 24-hour window, and the bitrate ceiling, which only applies to a relayed session. A free user on
their own network gets the full picture and unlimited time.

### Connection

| Feature | Free | Relay | Plus | Pro |
|---|---|---|---|---|
| Pair once with a six-digit code (device certificates, no account) | ✅ | ✅ | ✅ | ✅ |
| Nearby discovery (Bonjour), connect by address | ✅ | ✅ | ✅ | ✅ |
| Trusted Macs list: rename, forget, choose LAN or relay | ✅ | ✅ | ✅ | ✅ |
| Local network sessions, unlimited and unmetered | ✅ | ✅ | ✅ | ✅ |
| Relay sessions | 1 h/day | unlimited | unlimited | unlimited |
| Paired Macs | one | every Mac you own | every Mac you own | every Mac you own |
| Wake on LAN | ✅ | ✅ | ✅ | ✅ |
| Face ID lock on launch | ✅ | ✅ | ✅ | ✅ |
| Siri / Shortcuts: connect, end shells | ✅ | ✅ | ✅ | ✅ |

The paired-Mac row is `extraMacs`, and it is the one gate on the cheapest rung. It is a limit on a
list rather than on anything the service runs: pairing a second Mac costs the relay nothing, which
is why it sits here and not higher.

### Picture

| Feature | Free | Relay | Plus | Pro |
|---|---|---|---|---|
| Share a whole display | ✅ | ✅ | ✅ | ✅ |
| Share one running app, or a single window | ✅ | ✅ | ✅ | ✅ |
| Every Space / desktop as a picture (desktops panel) | ✅ | ✅ | ✅ | ✅ |
| Adaptive quality, fit vs fill | ✅ | ✅ | ✅ | ✅ |
| Session audio (hear the Mac) | · | ✅ | ✅ | ✅ |
| Picture in Picture | · | ✅ | ✅ | ✅ |
| Several windows in one picture (the mosaic) | · | · | · | ✅ |
| The sharpest picture over the relay (the bitrate ceiling) | · | · | · | ✅ |
| Privacy mode (dims the Mac's displays) | ✅ | ✅ | ✅ | ✅ |
| Screenshot with the system share sheet | ✅ | ✅ | ✅ | ✅ |

The note that used to be here proposed keeping this whole column free and gating privacy mode
instead. Both halves were answered on 20 September: **sound and Picture in Picture moved up to
Relay**, because they are what the field charges for and the entry rung had nothing but a number to
sell, and **privacy mode stayed free**, because Jump, Screens and Apple's own ARD all include it and
gating it would have bought nothing.

The bitrate row is not a picture that exists or does not exist. Every plan gets a picture, every
plan still adapts to the network, and the direct path is uncapped on all of them. What Pro decides
is how far a *relayed* stream may climb, which is the one row in the map that costs the operator
money every time it is used.

### Control

| Feature | Free | Relay | Plus | Pro |
|---|---|---|---|---|
| Pointer (tap where you look) and relative pointer (joystick/trackpad) | ✅ | ✅ | ✅ | ✅ |
| Scroll wheel | ✅ | ✅ | ✅ | ✅ |
| On-screen keyboard, hardware keyboard, modifier lock keys | ✅ | ✅ | ✅ | ✅ |
| Control mode vs Observe mode | ✅ | ✅ | ✅ | ✅ |
| Clipboard: pull from the Mac, push to it, copy | ✅ | ✅ | ✅ | ✅ |
| Clipboard history: the last twelve | · | ✅ | ✅ | ✅ |
| Quick commands and snippets: running one you already have | ✅ | ✅ | ✅ | ✅ |
| Quick commands and snippets: adding or editing one | · | · | · | ✅ |
| Macros: record, edit, fire | · | · | · | ✅ |

The note that used to be here proposed moving macros and quick commands to Pro, and that is what
happened. It is worth being precise about where the gate sits, because it is not on the feature:
the gate is on the button that *makes* one. A row of chips the user already has runs on every plan,
in every terminal, and only the editor is Pro. `PlanAccess.swift` folds macros, snippets and quick
commands into the single `macros` case on purpose, because they are one idea at three sizes.

### Terminals and files

| Feature | Free | Relay | Plus | Pro |
|---|---|---|---|---|
| Mac terminal (a shell on your Mac, in the session) | ✅ | ✅ | ✅ | ✅ |
| SSH servers: saved hosts, passwords in Keychain, host-key prompt | ✅ | ✅ | ✅ | ✅ |
| SSH port forwarding and tunnels | ✅ | ✅ | ✅ | ✅ |
| Multiple shells open as tabs | one at a time | one at a time | tabs | tabs |
| File browser on the Mac terminal (navigate, cd, preview) | ✅ | ✅ | ✅ | ✅ |
| File browser over SSH (SFTP, with an exec fallback) | ✅ | ✅ | ✅ | ✅ |
| Moving a file between the phone and the machine | · | ✅ | ✅ | ✅ |
| Told when a terminal stops and waits for an answer | · | ✅ | ✅ | ✅ |

Two rows here were wrong and are now right. **SSH servers are free**, and the capability has left
`PlanAccess.swift` altogether: the owner's question was "why block SSH for free", and on inspection
nothing about it costs the service anything, so what looked like a feature was a list. **Upload and
download exist** and are `fileTransfer` on Relay; the table here used to say they were never built,
which was true when it was written and has not been since.

Tabs stayed on Relay Plus, and that is the row doing the arguing on its own: it is a *concurrency*
gate rather than a capability gate, one shell is free on every plan, and the second one at the same
moment is what costs a login on the far end.

### Around the app

| Feature | Free | Relay | Plus | Pro |
|---|---|---|---|---|
| Live Activity (Lock Screen, Dynamic Island) | ✅ | ✅ | ✅ | ✅ |
| Home Screen widget, Lock Screen widget | ✅ | ✅ | ✅ | ✅ |
| macOS host widget (start/stop the host) | ✅ | ✅ | ✅ | ✅ |
| Session history (last 30 sessions, duration, path, bytes) | ✅ | ✅ | ✅ | ✅ |
| "Your Mac is waiting" / unlock notifications | ✅ | ✅ | ✅ | ✅ |

The note that used to be here called widgets and the Live Activity the most natural paid rows in
the document. They moved the other way: the widget extension cannot read StoreKit, so gating them
would have meant real work for no money, and nobody in the field gates a widget.

---

## 3. How the gates are enforced

Built and shipped. Every one of these is a check at the feature's own entry point, against the single
map in `PlanAccess.swift`, and every gate in the app draws itself through `PlanLocked` in the app's
`SharedControls.swift`.

- **Relay minutes** are metered by the relay, per device ID per 24-hour window. The plan arrives in
  the handshake as a StoreKit receipt, which the relay verifies against Apple's root certificate
  offline; `Relay/src/storekit.rs` is the whole of it.
- **Paired Macs** (`extraMacs`) are counted client-side at pairing time, against the pins the user
  has saved.
- **Several Macs at once** (`concurrentSessions`) is checked client-side at session start. It is the
  only row about how many of something may be *live*, and the only one whose cost scales with the
  number rather than with the user: every session held open is a control connection the relay goes
  on splicing whether or not anybody is looking at it.
- **Terminal tabs** (`shellTabs`) are counted client-side at "New shell".
- **Sound, Picture in Picture, moving files, macros and the bitrate ceiling** are each one check at
  their own entry point.
- **The mosaic** (`mosaic`) is checked on the phone where it is asked for, and the Mac then decides
  what it will actually build: it trims the tile count to six, the canvas to a 2560×1440 budget and
  the rate to 30, because every tile is a ScreenCaptureKit stream of its own and the client asking
  is a paired device rather than a trusted one. A Mac that has not been updated does not get asked
  at all — the request is a capture source an older host cannot decode, so it is negotiated with
  `ServerHello.supportsMosaic` rather than sent blind. The host also refuses *input* while a mosaic
  is the current source, at the single guard the input path passes through: a point on a canvas has
  no meaning on the Mac until a tile has been chosen for it, and that choice is made on the phone.
- **Terminal alerts** (`terminalAlerts`) are two checks on the phone, and neither of them is a
  control the user is looking at. A session that comes up refuses to register its APNs device token
  with the Mac on a plan without it, and a shell that stops refuses to raise its banner. The first
  is the one that carries the weight: the Mac sends a notification to a token and knows nothing else
  about the user, so a phone that never hands one over cannot be reached by a Mac that has been left
  running. A plan that lapses sends an *empty* registration on the next connection, which is how the
  Mac is told to forget the token it was given while the plan did include it. Both checks fail
  closed while the entitlement has not been read, since neither waits for a tap.
- **Client-side means bypassable.** A patched app can claim anything, which is the same trust level
  as the relay's own plan field, and is the right trade at this size. The real fix, when it matters,
  is verifying Apple's signed transaction offline, and the relay now does that for the one thing
  that costs it money.

**How a locked feature should appear:** visible, drawn as itself, and one tap to the paywall. Never
hidden. A feature a user cannot see cannot make them want it, and hiding the terminal from a free
user just means they never learn it exists.

**Extended on 20 September, because "with a lock" was read too literally twice.** The control is
drawn as itself, in its normal shape and with its normal icon, dimmed, with a small plan-name badge
(RELAY, PLUS or PRO) on its top-trailing corner, and the tap opens the paywall. Never a padlock, and
never a badge in the control's place. The badge was beside the control when this paragraph was
written and moved onto its corner on the owner's call, which is a correction to the paragraph rather
than a change of rule: beside the control it took the badge's own width out of the row, so a locked
control was a different size from the unlocked one and the layout around it moved to pay for it. The
first attempt drew a padlock the size of the control it replaced, which answered "what was that
button" with nothing; the second kept the words and swapped only the icon, so "Add a server" ended
in a padlock where the plus had been, which is the same failure in a smaller place. Both are the
reason the rule is now about the *whole* control rather than about the words alone. The code that
draws it is `PlanLocked` in the app's `SharedControls.swift`, and every gate in the app goes through
it except one: the "New shell" item in a server row's menu, which is a line of a system menu rather
than a view the app lays out, and so cannot wear a badge. It keeps its own name and its own glyph
and its tap opens the paywall, which is as much of the rule as a menu row can hold.

---

## 4. What is built, in flight, and not started

**Built and running** ✅
- Local + relay sessions, pairing, trusted Macs, wake on LAN, Face ID
- Display / app / window sources, desktops, adaptive quality
- Clipboard + history, macros, quick commands, session audio, PiP, terminal alerts, privacy mode,
  screenshots
- Mac terminal and SSH terminal, with tabs
- File browser on **both** terminals (phase 1 and 2), including SFTP with an exec fallback
- Live Activity, widgets (iOS + macOS host), session history, Siri intents
- Relay: metering per device per day, three products in one subscription group
- Free tier at 1 h/day; every paid plan unlimited; relay copy aligned across app, site and terms

**In flight** 🔧
- **A video "lane" and a fallback** (protocol v12). See the correction in §5 first: the premise I
  gave for this was wrong. What it actually adds is a way for the client to ask the host to move
  video onto the control channel, chunking so a keyframe fits, a rate cap while it is there, and a
  probe of the lane it left. On the direct path that is a genuine fallback from the dedicated
  video socket; on the relay path it is only a rate reduction, because video is already there.
- **Per-plan relay allowances** — the relay learns the plan from the handshake; free gets one hour
  and every paid plan is unlimited.
- **The mosaic** — several of the Mac's windows in one picture, Pro. The Mac half is built and
  proved on its own: one ScreenCaptureKit stream per tile, copied out of the pool ScreenCaptureKit
  reuses, composited with CoreImage into a single encoded canvas, and the limits checked against a
  running Mac (`Tools/CaptureProbe --mosaic` with nine sources builds six; with a 7680×4320 canvas
  it builds 2560×1440; at 60 fps it runs at 30). The phone half is built too: pick several sources
  in the sources panel, rearrange them as a list, give one or another more room, tap a tile to go
  into it, and a back control in the status pill to return. An arrangement is remembered per Mac
  and comes back thinned to the windows that still exist.
  What is not done is freeform positions (drag where a tile sits, rather than order and size), and
  one thing still has to be seen with a real client: **that the iOS renderer decodes a composited
  canvas**. The file the probe writes plays back, which retires the timestamps, the pixel format and
  the buffer ownership, but the client's own surface is where a host-made frame failed once before.
  A tile for a window that is on another Space is black and always will be, because nothing is
  rendering it.

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

### Paying users were metered as free, and now are not

**Closed.** The relay used to decide who was paid by checking a key against a server-side list, and
nothing minted a key that could go on it: the app generated a random UUID locally, so every real
subscriber got the free allowance and the app papered over it by saying the subscription was active
and to try again later.

Two things closed it. The app declares its plan in the relay handshake, and **the relay verifies
Apple's signed transaction itself**: `Relay/src/storekit.rs` checks the JWS against Apple's root
certificate, offline, with no backend of ours and no accounts, and it answers "paid?" and "which
plan?" at once. `signalling.rs` uses it to decide whether a client's plan is Apple's or its own
claim.

One exception is still in the code deliberately, and is worth knowing about before the next release.
An *unproven* claim is still honoured, because reading one as free on the day verification shipped
would have taken every existing subscriber down to the free allowance. `Relay/src/config.rs` holds
the switch; the reasoning is in `RelayPlan.swift`.

The caveat from before still stands: revocation and refunds need Apple's server API, so a refunded
user keeps access until the JWS expires.

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
- **The relay enforces nothing new until it is redeployed.** The app and site say one hour/day for
  Free and unlimited for paid plans; the running server has whatever it was started with.
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

**Done since (20 September):** the site and `Config/Products.storekit` now agree on the same three
prices, $4.99 a month, $14.99 a month and $39.99 a year, so local testing shows what a visitor is
told. Neither of them is the authority: **App Store Connect is**, and it has not been set. Type
these three in there, or change both files together, but do not change one alone.

**Done since, and verified:** the relay now verifies the StoreKit transaction instead of trusting
the plan the client claims — the JWS is checked against Apple Root CA - G3, pinned in this
repository, and a verified receipt always wins. The **claimed plan is still believed when no
receipt arrives**, which is deliberate: a shipped app cannot send one, so verification-only would
drop every existing subscriber to the free allowance on deploy day. `PEERINGD_TRUST_CLAIMED_PLANS=0`
closes it, and the removal condition is in the README: deploy, watch `plan_trust="claimed"` in the
logs, then turn the fallback off.
