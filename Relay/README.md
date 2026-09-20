# peeringd

The relay that lets a phone reach its Mac from outside the local network.

Both ends sit behind NATs that will not admit unsolicited traffic, so both connect *outward* to
this process. It introduces them, splices their control connections, and forwards their video
datagrams.

Both ends address the relay, and for most of this project's life neither learned the other's
address at all — this process was the only thing that knew both, which is what lets a session open
between two machines neither of which can be dialled. That is still how a session *starts*. Either
end may now ask (`requestPeerAddress`) and be told where its peer was last seen, so the two can try
a path between themselves and keep this one as the fallback. What comes back is an observation and
no promise: whether a peer's NAT will admit a third party is not something the relay can know, and
the two ends settle it by trying. **What this process can read does not change** — a direct path is
sealed with the same key it was never told.

## What it does not do

**It cannot read anything it carries.** Control is a TLS session belonging to the two ends, which
the relay copies without terminating. Video is sealed with a key the two ends exchanged over that
TLS session, and which the relay was never told. Its tokens are addressing hints, not credentials.

That property is the product. "Your Mac's screen does not pass through our servers in a form we can
see" has to stay true as this code grows, and the way to keep it true is to keep this process too
stupid to break it. If a change here would let the relay inspect, alter, or authorize traffic, the
change is wrong.

A consequence worth understanding: **anyone who learns a Mac's device ID can ask the relay to open
a pipe to it.** That is deliberate. The relay is not the thing that grants access — the TLS
handshake and the pin are, and someone who knows the ID gets a pipe and then fails the handshake.
Having the Mac hand its paired-device list to the relay would let it refuse earlier, at the cost of
giving the server a map of who is paired with whom. Silence is the better trade.

## Running it

```sh
cargo run                       # loopback: signalling on :8443, control on :9443
cargo run --release             # same, optimised
cargo test                      # the unit tests and the end-to-end socket tests
```

With no configuration it listens on all interfaces, binds one shared socket for every session's
video, and serves signalling in plaintext. That is exactly right for pointing both apps at
`127.0.0.1`, and never right for a public address.

| Variable | Default | Meaning |
|---|---|---|
| `PEERINGD_SIGNAL_ADDR` | `0.0.0.0:8443` | Signalling listener |
| `PEERINGD_CONTROL_ADDR` | `0.0.0.0:9443` | Control relay listener |
| `PEERINGD_VIDEO_BIND` | `0.0.0.0:0` | Address the **one** video socket binds to. Every session shares it, so `0` is fine — the port chosen is reported to both ends in `ready`, and `PEERINGD_PUBLIC_VIDEO_PORT` is how a firewall or port-forward maps it |
| `PEERINGD_VIDEO_PORTS` | — | **Retired.** Sessions no longer have ports of their own, so this does nothing. A value left in an env file is read, ignored and warned about at startup rather than being allowed to stop the relay — see below |
| `PEERINGD_TLS_CERT` | — | Certificate for signalling. Both this and the key, or neither |
| `PEERINGD_TLS_KEY` | — | Private key for signalling |
| `PEERINGD_SESSION_TTL` | `300` | Seconds a session survives without activity |
| `PEERINGD_MAX_SESSIONS` | `1000` | Sessions that may exist at once. A session costs a kilobyte of bookkeeping before its splice exists (see Cost), and asking for one is unauthenticated, so this is what turns "someone loops `ConnectToHost`" from an OOM kill into a refusal. Zero is refused as a value: a relay that answers nothing looks healthy, and that is an outage nobody diagnoses from the config |
| `PEERINGD_MAX_CONNECTIONS` | `4096` | Sockets that may be open on the signalling listener at once. Has to be larger than the number of registered Macs, since each holds its registration socket open for as long as it runs. A connection beyond it is closed rather than queued |
| `PEERINGD_HANDSHAKE_SECONDS` | `10` | How long a socket has to finish becoming a WebSocket, counting the TLS handshake. Without it a peer that opens a connection and says nothing holds a task and a file descriptor indefinitely |
| `PEERINGD_IDLE_SECONDS` | `90` | How long an established signalling connection may sit silent. Comfortably longer than the Mac's 25-second keepalive on purpose: a registered Mac is idle between pings and must not be dropped for it |
| `PEERINGD_FREE_MINUTES` | `30` | Relay minutes per device in each rolling 24-hour window for a client on the free plan. The app draws its "free relay time" bar from its own copy of this number and its own copy of the window arithmetic (`RelayPlan.allowanceSeconds`, `SessionModel.relayPeriodStart`) — change the relay and those together, or the bar lies |
| `PEERINGD_RELAY_MINUTES` | `180` | The same, for a client the Relay plan applies to: one whose receipt proves it, or one whose claim is believed because the switch below is on. `0` turns a plan off rather than making it unlimited; Relay Plus and Pro are not metered and have no setting |
| `PEERINGD_PAID_KEYS` | — | Comma-separated API keys that bypass the quota entirely. See the note under "Plans" below |
| `PEERINGD_TRUST_CLAIMED_PLANS` | `0` | Whether a client's own statement of its plan is believed when no verifiable receipt arrives. **Closed by default**, because a claim is not evidence. `1` is for beta testing, where a TestFlight build's receipt is a sandbox one and is refused by name, so a tester is metered by what they claim instead. See "Plans" below |
| `PEERINGD_WEB_ADDR` | `127.0.0.1:8080` | Where the site is served. **Loopback by default** — see below |
| `PEERINGD_WEB_ROOT` | `site` | Directory the site is read from. Relative paths resolve against the working directory |
| `PEERINGD_USAGE_LOG` | `/var/lib/peeringd/usage.log` in the shipped unit, unset otherwise | File the relay-time counter is written to. See "Relay time is remembered" below |

### Relay time is remembered

The counter used to live in a `HashMap` for the lifetime of the process, which made `Restart=always`
an unlimited relay: a crash loop, a deploy, or an operator typing `systemctl restart` handed every
client the full allowance back. That is bandwidth rather than money, but bandwidth is what the relay
sells, so it is now written down.

`PEERINGD_USAGE_LOG` names the file. The shipped unit sets it to `/var/lib/peeringd/usage.log` and
declares `StateDirectory=peeringd`, which is what makes that directory exist, own it as the service
user, and keep it writable under `ProtectSystem=strict`. A value in `/etc/peeringd.env`
overrides the unit's default.

It is an append-only log rather than a database, and the shape of the data is what decides that: one
line per **charge**, at most one line per client per day, and a question that is only ever "how many
seconds has this client spent in this window". A charge is a stretch of a session rather than a
whole one (see "A session pays as it runs" below), so a long session writes a line every fifteen
seconds while it is open. Each line is a JSON object
(`{"c":"<device id>","w":<window>,"s":<seconds>}`), which is why a device id containing a pipe or a
newline is stored and read back unchanged, and why a machine that dies mid-append costs one
charge's seconds rather than the whole file. The file is rewritten compactly, through a temporary
file and a rename, once it is both over four megabytes and at least twice what a rewrite would
keep: the second half of that condition is what stops a file of distinct clients from being
rewritten over and over, since a compaction that drops nothing is a compaction that happens again
on the next charge.

Three things it does not do, worth knowing before relying on it:

- **A crashed machine can still lose the last charges.** Each record is `fsync`ed, so what has been
  written is on the disk; a stretch that was still running when the kernel stopped is not, and since
  a charge is taken every fifteen seconds, that is the most a crash can cost.
- **Deleting the file resets everyone.** It is the only copy.
- **Nothing migrates.** A window that has passed is dropped on the next start, which is correct,
  because the allowance it counted against has passed too.

If the file cannot be opened the relay starts anyway and says so loudly at startup, with the path
and the reason. Not persisting usage costs relay time; refusing to start costs the service.

### Plans, and what the relay does not check

Relay time is metered per rolling 24-hour window, and how much there is depends on the plan the
client is metered on:

| Plan | Wire name | Allowance |
|---|---|---|
| Free | `free` | 30 minutes a day |
| Relay | `relay` | 3 hours a day |
| Relay Plus | `plus` | unlimited |
| Pro | `pro` | unlimited |

The client states its plan in `connectToHost`, and what the relay meters by is the receipt that
proves it. So beside `plan` the client can hand over a **receipt**: the JWS StoreKit gives the app
for its transaction, sent in the same message as `jwsRepresentation`. When that verifies, the plan
comes from the product named inside it and the claimed `plan` is ignored. `src/storekit.rs` is the
whole of the verification; read its header before changing anything in it.

**What is checked, in order:** the message is under 16 KB; three base64url segments; the header
parses and says `alg: ES256` (nothing else, ever); the `x5c` chain is decoded as standard base64 and
built with `rustls-webpki` to an anchor that is **pinned in this repository**, `src/AppleRootCA-G3.cer`
(583 bytes, SHA-256 `63343abf…9179`), embedded with `include_bytes!` so no deployment can be missing
it or swap it; Apple's two marker extensions are present on the leaf and on the certificate that
actually signed it; the signature verifies over the literal text; and only then are the payload's
`bundleId`, `productId`, `expiresDate`, `revocationDate` and environment read.

**The product names the plan:**

| Product ID | Plan |
|---|---|
| `pl.dmq.peering.relay.monthly` | `relay` |
| `pl.dmq.peering.relayplus.monthly` | `plus` |
| `pl.dmq.peering.relay.year` | `pro` |

**A verified receipt always wins, even downward**: a Relay subscriber who sends a Relay receipt is
metered as Relay whatever their `plan` field says. Anything refused or unreadable is logged with its
reason and metered as free, unless the switch below has been turned on, in which case the claim
decides; and a claim that is missing, unknown or malformed is the free allowance, never unlimited.
Every session line carries `plan_trust="verified"`, `"claimed"` or `"neither"`, so which path was
taken is visible in the log rather than taken on faith.

What a false plan does not buy is access. The relay carries a TLS session belonging to the two ends
and cannot read it or forge it, and a Mac is reached by passing its own pairing handshake — so
lying about a plan buys free bandwidth and nothing else.

**Missing, unknown or malformed is always the free allowance, never unlimited.** Absent, empty, a
misspelling, a name from a newer app, a JSON number where a string belongs — all of it resolves to
free. Case and surrounding spaces are forgiven, because they cannot be a lie, only a typo, and
metering a paying subscriber as free is the failure this exists to remove. What the parse will
never do is find a paid plan in a string that is not exactly one of the four names above; the
relay logs the plan it applied on every session it allocates, so this is checkable from the log
rather than from a promise.

**A claimed plan buys nothing on its own, and that is the default.** It is what closes the hole the
claim used to be: a patched app can still send `"plan":"pro"` with no receipt, and all it gets for
saying so is the free allowance. The claim is not thrown away (the session line still records which
path decided, as `plan_trust="verified"`, `"claimed"` or `"neither"`), but it decides nothing unless
an operator has said it should.

**`PEERINGD_TRUST_CLAIMED_PLANS` (default `0`) is the switch, and it is for beta testing.** With it
set to `1`, a client that sends no receipt, or one that does not verify, is metered by the plan it
claims. The reason an operator sets it is TestFlight: a beta build's receipt is a **sandbox** one,
and the relay refuses those by name (`not_a_real_purchase`) rather than treating them as proof,
because Apple hands sandbox transactions out for nothing to anyone with a developer account. So a
tester on a `pro` build is metered as free: thirty minutes a day on a build that says it is
unlimited, until someone sets the variable and restarts. That is what a beta looks like from the
relay's side rather than a fault in the receipt check, and it is worth knowing before reading a
log, because a session line saying `receipt refused` with `reason=not_a_real_purchase` is Apple's
test purchase being turned down on purpose. Set the variable back to `0` when the beta is over; for
as long as it is on, the old hole is open, and any client can have any plan by asking for it.

**It is also the rollback for verification itself.** No receipt Apple actually signed has been
through this code yet, only ones minted by the tests, so the first production receipt is the first
real test of it. If real receipts turn out to be refused, and a paying subscriber reports being
metered as free, `PEERINGD_TRUST_CLAIMED_PLANS=1` and a restart is the way back to the behaviour
that shipped before any of this: every client metered by the plan it claims. That is a bad state to
stay in and a much better one to be in for an hour than a fleet of subscribers on thirty minutes a
day.

**What a false plan does not buy is *access*.** The relay carries a TLS session belonging to the two
ends and cannot read it or forge it, and a Mac is reached only by passing its own pairing
handshake, so lying about a plan buys bandwidth and nothing else.

One thing verification does **not** establish: that the receipt belongs to the device presenting
it. Nothing binds the JWS to a phone, so a receipt is a bearer token and sharing one shares the
plan until it expires. Binding it needs Apple's device-verification endpoint, which the relay
deliberately does not call — the honest description is that this stops people forging a purchase,
not that it stops them sharing one.

**`PEERINGD_PAID_KEYS` is the one grant the relay holds rather than takes on trust**, which is why
it is kept even though nothing mints a key anyone can put in it. The app generates its own UUID in
the Keychain and sends that, so the set is empty in practice: every client is metered by the plan
its receipt proves, or by the free allowance when it has none, and a key that *is* in the set
bypasses the meter whatever plan the client names. It is honest to call this a hook rather than a
feature: nothing in the app displays that UUID, and nothing issues one, so filling the variable in
today means reading the value out of the device by some other means. What a claimed plan used to do
(a device given unlimited relay by asking for it) is what this variable does now, and a plan that
becomes verifiable is what would replace it.

**The video socket is one port, and it used to be one per session.** Sessions now share a socket
and each datagram says which session it belongs to, so a host with a handful of forwarded UDP ports
— which is what a shared-IPv4 VPS gives you — can carry any number of concurrent sessions instead
of one. A host that used to set `PEERINGD_VIDEO_PORTS=40000-40100` now sets
`PEERINGD_VIDEO_BIND=0.0.0.0:<one port>` and forwards that one port; the startup log prints the
address and port actually bound, which is the number to check a firewall against. What a closed
port looks like is *control working and video never arriving*, which is a miserable thing to debug
from the symptom.

**What the relay reads, since it is no longer nothing.** Each datagram begins with the sender's
video token — 16 bytes, which the relay uses to find the session and strips before forwarding — and
behind it sits an 8-byte counter and the sealed payload. So the relay sees which session a packet
belongs to, its size, and its position in the sequence. It cannot read or forge a byte of what it
forwards: the payload is sealed with a key the two ends derive from a secret they exchanged inside
the TLS session, and the relay was never told it. `src/lib.rs` states this in the same terms, and
that statement is the one to keep true.

The relay reports the address a client reached it on as the address to connect back to, so a
directly-addressed server needs no configuration for this. `RUST_LOG=debug` for per-connection
detail; `info` shows registrations and session allocations.

### A session pays as it runs

The relay-time counter is charged while a control splice is open, once every fifteen seconds
(`CHARGE_PERIOD` in `src/quota.rs`), and not only when the splice ends. The check made when a
session is allocated is the other half of the same rule, and it is the half that is easy to mistake
for the whole of it: it reads the counter at the instant it hands out a connection, and a connection
that is already open does not pass that check again. Charging on a timer is what stops a client with
a second of credit left from opening a splice and holding it open for as long as it likes, and the
same charge is what makes a restart mid-session cost at most the last fifteen seconds rather than
the whole session.

When the plan's allowance for the window is gone, **the relay ends the session**: the control
sockets are closed, the session's video routes are retired with it (so a Mac still sending frames is
sending them to a token the relay no longer knows), and the meter writes what the last stretch cost.
Several things follow from that which are worth knowing before reading a log or a bug report:

- **The session ends as a dropped connection, not as a message.** Everything after the control
  token is a TLS session belonging to the two ends and this process cannot write into it, so there
  is nowhere to say "your allowance is spent". The app finds out the way it finds out about any
  dropped control connection, and the reason arrives on the next attempt, when `connectToHost` is
  answered with `{"type":"error","code":"quotaExceeded",…}`.
- **The log line to grep for is `session ended: the plan's relay allowance for this window is
  spent`**, at `info`. It is the only line that distinguishes a client that ran out of allowance
  from one that hung up.
- **The overshoot is one charge period, not one session.** A client whose allowance runs out
  mid-period keeps relaying for the rest of that period, which is bounded by fifteen seconds.
- **Paid keys, Relay Plus and Pro are charged the same way and never ended by it.** Their usage is
  in the log like everyone else's; it just does not bound anything. Only a plan with an allowance
  (`PEERINGD_FREE_MINUTES`, `PEERINGD_RELAY_MINUTES`) can run out.

**Nothing tells the app in advance, either.** The app's "free relay time" bar is drawn from its own
arithmetic rather than from the relay's counter, so a session that is about to be cut off is not
visibly about to be cut off. Reaching for a countdown would mean the app asking the relay how much
it has left, which is a question the relay has no message for today.

### The free allowance follows the key, not the install

The counter used to be keyed by the `clientId` the client sends, which is a UUID the app mints on
first run and keeps in `UserDefaults` (`Peering.deviceID` in `DeviceIdentity.swift`). Reinstalling
the app minted a new one, the relay saw a client it had never met, and the free allowance started
over. **That is closed now.**

`connectToHost` carries three optional fields beside the client id, the same three a Mac sends when
it registers:

```jsonc
// phone → relay
{"type":"connectToHost","hostId":"…","clientId":"…","protocolVersion":3,
 "plan":"free","publicKey":"04…","proof":"3045…","proofTime":1760000000}
```

`proof` is a signature over `device_proof::client_payload`, which is a domain-separated string:

```
peeringd-client-registration-v1\n<clientId>\n<proofTime>
```

**The domain is separate from the host's on purpose.** Both are signed with the same P-256 key by
the same device and both carry their three fields under the same names, so the version tag inside
the signed string is the only thing keeping a client registration from being presentable as a host
registration for the same id. `device_proof` has a test for exactly that.

When the proof verifies, the relay meters the public key rather than the announced id, and the id
becomes a name in a log line (the `metered_by` field on the `session allocated` line says which of
the two it used). The key is in the Keychain and iOS keeps those through a reinstall, so the second
install spends what the first one spent.

Three things worth being plain about:

- **A client that sends no proof is metered by its id**, exactly as before. The fields are optional
  and their absence is not a refusal: refusing there would turn a clock skew into an outage for
  somebody who has done nothing wrong.
- **The proof is not authorization.** It decides an allowance. Whether a session may be driven is
  decided by the pairing handshake and the pin, which this changes nothing about.
- **Nothing migrates.** Usage already recorded against an id stays there; the first request a
  client makes with a proof starts a counter under its key. A device that was mid-window when this
  shipped gets the rest of that window twice, once under each, which is a few minutes.

### On a server

**Only one of the relay's four listeners can be proxied.** Signalling is a WebSocket and nginx can
front it. Control is a raw TCP splice carrying a TLS session belonging to the two ends — nginx's
`sites-enabled` cannot proxy it, and neither can anything else that expects HTTP. Video is UDP. The
site is ordinary static HTTP and can be proxied like any other website, but it shares a hostname
with signalling and the collision is worth reading about below. So the shape depends on whether the
machine already serves HTTPS.

| Port | Protocol | Proxied? |
|---|---|---|
| signalling | TCP | Yes, if you want — see B |
| control | TCP | **No.** Direct only |
| video | UDP | **No.** Direct only |

**DNS** — an `A` record for the relay host. Add an `AAAA` if the server has IPv6, and check which one
clients actually pick: a broken IPv6 route shows up as a connection that hangs rather than one that
fails, which is much harder to diagnose.

#### A — direct ports

Simplest, and right for a machine with nothing else on it. The relay owns its ports and terminates
its own TLS.

```ini
Environment=PEERINGD_SIGNAL_ADDR=0.0.0.0:8443
Environment=PEERINGD_CONTROL_ADDR=0.0.0.0:9443
Environment=PEERINGD_VIDEO_BIND=0.0.0.0:9444
Environment=PEERINGD_TLS_CERT=/etc/letsencrypt/live/getpeering.app/fullchain.pem
Environment=PEERINGD_TLS_KEY=/etc/letsencrypt/live/getpeering.app/privkey.pem
```

Bind 443 if it is free — it is the one port guest and corporate networks never block. Otherwise use
anything, accepting that a restrictive network may refuse it.

#### B — nginx in front of signalling

For a machine already serving HTTPS, where 443 is taken. nginx terminates TLS for the WebSocket and
the relay does not need a certificate at all.

```nginx
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name getpeering.app;

    ssl_certificate     /etc/letsencrypt/live/getpeering.app/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/getpeering.app/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Not optional. A Mac that is registered holds this socket open and says nothing for
        # minutes at a time, and nginx closes an idle proxied connection at 60 seconds. Drop it
        # and the Mac looks offline to every phone, intermittently, for no visible reason.
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
```

```ini
Environment=PEERINGD_SIGNAL_ADDR=127.0.0.1:8443
Environment=PEERINGD_CONTROL_ADDR=0.0.0.0:9443
Environment=PEERINGD_VIDEO_BIND=0.0.0.0:9444

# Required here, and the one setting that is easy to miss. Without it the relay reports the address
# each client reached it on as the place to connect for control and video — which is right when
# clients address it directly, and behind nginx is 127.0.0.1, so every client would be told to
# connect to itself.
Environment=PEERINGD_PUBLIC_HOST=getpeering.app
```

The relay's signalling listener stays on loopback; nginx is the only thing that reaches it. Control
and video are opened directly in the firewall and are **not** proxied.

#### C — the site, on the same name as signalling

`site/` in this crate is the marketing and legal site, and the relay serves it itself — see
`web.rs`. It binds `127.0.0.1:8080` by default, on the same reasoning as the signalling listener:
whatever already terminates TLS on the machine is what should face the internet.

**The two share a hostname, and that is the whole of the complication.** The app opens signalling at
`wss://getpeering.app/` — the root path — so a `location /` that serves files would swallow it. The
fix is to route on the one header that distinguishes them, which costs two maps and no application
change:

```nginx
# A WebSocket upgrade asks for the relay; everything else is somebody reading the site.
map $http_upgrade $connection_upgrade {
    default     close;
    "websocket" upgrade;
}

map $http_upgrade $peering_upstream {
    default     "127.0.0.1:8080";   # the site
    "websocket" "127.0.0.1:8443";   # signalling
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name getpeering.app;

    ssl_certificate     /etc/letsencrypt/live/getpeering.app/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/getpeering.app/privkey.pem;

    location / {
        proxy_pass http://$peering_upstream;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # Only the WebSocket needs this. A Mac that is registered holds its socket open and says
        # nothing for minutes at a time, and nginx closes an idle proxied connection at 60
        # seconds. Drop it and the Mac looks offline to every phone, intermittently, for no
        # visible reason.
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
```

```ini
Environment=PEERINGD_WEB_ADDR=127.0.0.1:8080
Environment=PEERINGD_WEB_ROOT=/srv/peering/site
```

Two pages on the site exist for the App Store listing rather than for visitors: `/privacy` and
`/terms`. Both are served as plain HTML with no JavaScript, because a reviewer's browser may not run
any — they are the URLs to paste into App Store Connect.

#### Publishing a Mac release

The Mac app updates itself with [Sparkle](https://sparkle-project.org), which is already a package
dependency of the `MacCastHost` target. Three things have to line up, and only the first is code:

1. **The feed URL and the public key** are in `Config/MacCastHost-Info.plist` — `SUFeedURL` points at
   `/updates/appcast.xml` on this site, and `SUPublicEDKey` holds the Ed25519 public key that every
   download is verified against.
2. **The private key** goes in the login keychain of whoever publishes, once, and never in this
   repository. If it is lost, no existing install can be updated again — they would all have to be
   replaced by hand.
3. **The disk image and the appcast** land in `site/`, which the relay serves.

```sh
# One-time: the signing key pair. Keep the private half where it is; add the printed public half
# to Config/MacCastHost-Info.plist as SUPublicEDKey.
"$SPARKLE/bin/generate_keys"

# Build a release. The version that matters is CFBundleVersion (sparkle:version in the feed) and it
# must increase every time, or no installed copy will ever be offered this build.
#
# **Pass it on the command line, every release.** The project carries a date-stamped value as a
# floor rather than as the answer: it is there so that a plain archive is at least newer than the
# first release, which it was not: `MacCastHost` sat at CFBundleVersion 1 while the iPhone app was
# stamped 202609161, and Sparkle compares numbers, so a second release built from the project as it
# stood would have carried the number the installed copy already had and been offered to nobody.
# Nothing about that fails loudly: the upload succeeds, the feed updates, and the update simply
# never appears on any Mac.
#
# The number is YYYYMMDD and a revision digit, so today's first build is 202609200. Give both
# settings the same value; the marketing version is what a person reads on the About pane.
VERSION=$(date +%Y%m%d)0
xcodebuild -project MacCast.xcodeproj -scheme MacCastHost -configuration Release \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
  -destination 'generic/platform=macOS' \
  -archivePath /tmp/Peering.xcarchive archive
# Proof, before the upload rather than after it, that the bundle carries the number you meant. The
# failure this catches is the quiet one: an archive built with no override, uploaded, and offered
# to nobody.
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
  /tmp/Peering.xcarchive/Products/Applications/Peering.app/Contents/Info.plist

# The same kind of proof for the two properties an Intel Mac depends on, and for the same reason:
# both fail silently. A thin archive builds and notarises exactly like a universal one, and the
# only place it shows is on the machine that cannot open it. The destination above is what
# produces both slices; that directory is now the only Mac release path, so a build that skips it
# is checked here rather than trusted.
#
# The floor matters as much as the architecture, and the two have to move together. Xcode writes
# `LSMinimumSystemVersion` from `MACOSX_DEPLOYMENT_TARGET`, and `generate_appcast` copies it into
# the feed as `sparkle:minimumSystemVersion`. Lower the floor without going universal and the feed
# starts offering macOS 15 to Intel Macs that cannot execute the binary, which turns a silent
# exclusion into a broken update.
ARCHIVE_APP=/tmp/Peering.xcarchive/Products/Applications/Peering.app
lipo -archs "$ARCHIVE_APP/Contents/MacOS/Peering"                     # expect: x86_64 arm64
lipo -archs "$ARCHIVE_APP/Contents/PlugIns/MacCastHostWidgetExtension.appex/Contents/MacOS/MacCastHostWidgetExtension"
                                                                      # expect: x86_64 arm64
xcrun vtool -show-build "$ARCHIVE_APP/Contents/MacOS/Peering" | grep minos   # expect: minos 15.0

# Notarise before packaging, or every download is quarantined and the app is a dialog nobody
# finishes. This step needs an Apple ID with an app-specific password and a team.
xcrun notarytool submit /path/to/Peering.app --keychain-profile <profile> --wait
xcrun stapler staple /path/to/Peering.app

# Package and sign. The source is the archived app from above, not a build product: the disk image
# that shipped was arm64-only, and the archive it should have come from was not, so this line is
# where that went wrong if it goes wrong again.
hdiutil create -volname Peering -srcfolder "$ARCHIVE_APP" -ov -format UDZO \
  /tmp/Peering-<version>.dmg

# And the image is what actually ships, so this is the copy of the check that counts. `lipo` cannot
# see inside a disk image, so mount it read-only and look at the app within.
hdiutil attach -nobrowse -readonly -mountpoint /tmp/peering-verify "/tmp/Peering-<version>.dmg"
lipo -archs /tmp/peering-verify/Peering.app/Contents/MacOS/Peering     # expect: x86_64 arm64
hdiutil detach /tmp/peering-verify

# The feed. `generate_appcast` reads a directory of disk images, signs each with the key from the
# keychain, and writes appcast.xml beside them.
"$SPARKLE/bin/generate_appcast" /tmp/release-<version>/

# Publish: the newest image under a stable name, so /download can link to it forever, and the feed
# beside it.
cp /tmp/Peering-<version>.dmg site/download/Peering.dmg
cp /tmp/release-<version>/appcast.xml site/updates/appcast.xml
cp /tmp/Peering-<version>.dmg site/updates/
```

`$SPARKLE` is the checkout Xcode's SwiftPM left behind:

```sh
SPARKLE=$(find ~/Library/Developer/Xcode/DerivedData -type d \
  -path "*SourcePackages/artifacts/sparkle/Sparkle" 2>/dev/null | head -1)
```

Two notes that cost an afternoon each if missed. **The version in the appcast is `sparkle:version`,
which is `CFBundleVersion`** — not the marketing version people read — and Sparkle compares it as a
number, so it has to increase monotonically. And **nothing is installable without the signature**:
an enclosure without `sparkle:edSignature`, or one signed by a different key, downloads and then
refuses to install, which from the app's side looks like an update that simply never appears.

Disk images are not in the repository — `site/download/` and `site/updates/` hold what the last
release put there.

#### Behind Cloudflare

**Cloudflare's proxy carries HTTP and HTTPS and nothing else.** It proxies a fixed list of ports —
443, 8443 and a handful of others — and it does not proxy UDP at all outside Spectrum, which is
priced for enterprises rather than for this. So of the relay's three listeners, Cloudflare can
carry exactly one: signalling.

That has a consequence that is easy to miss and unpleasant to debug: **the name in
`PEERINGD_PUBLIC_HOST` must not be proxied.** Clients open control and video against that name, and
if it has the orange cloud they will be sent to Cloudflare, which will drop the connection because
9443 is not a port it proxies and UDP is not traffic it carries. What that looks like from the app
is signalling working perfectly and the session never opening — which reads as a relay bug rather
than a DNS setting.

So use two names:

| Name | Cloudflare | Carries |
|---|---|---|
| `getpeering.app` | Proxied (orange) | The site, and signalling. Cloudflare → nginx → the relay's loopback listeners |
| `relay.getpeering.app` | **DNS only (grey)** | Control and video. Clients reach the server directly |

```
PEERINGD_PUBLIC_HOST=relay.getpeering.app
```

Signalling still benefits from the orange cloud: the WebSocket rides HTTPS on 443, which is the one
port nothing blocks.

#### IPv6

Worth being deliberate about, because a proxied name hides the problem and the direct ports cannot.

**Bind dual-stack if the server is IPv6.** The defaults are `0.0.0.0`, which is IPv4 only. On a
server whose clients arrive over IPv6, set:

```
PEERINGD_SIGNAL_ADDR=127.0.0.1:8443
PEERINGD_CONTROL_ADDR=[::]:9443
PEERINGD_VIDEO_BIND=[::]:0
```

`[::]` accepts IPv4 as well on Linux, where `net.ipv6.bindv6only` is 0 by default, so this covers
both.

**An IPv6-only server is a real limitation, and it constrains both ends.** Cloudflare's proxy hides
the problem for signalling — it terminates the connection and reaches the origin however it can, so
a dual-stack edge covers an IPv6-only origin. But control and video go straight to the origin, so
*both* the phone and the Mac must have IPv6 to open a session. The Mac matters more than the phone,
and is easier to overlook: it is the end that has to be reachable at all times, from whatever
network it happens to be sitting on.

What it looks like when it fails is signalling connecting, the host appearing online, and the
session never opening — on some networks and not others, which reads as flakiness rather than as a
missing address family.

Three ways out, in the order worth trying:

1. **Buy an IPv4 address.** Most providers that offer IPv6-only instances sell an IPv4 for a small
   monthly fee — around €0.50 at the common European hosts. This is by far the cheapest fix, and it
   is a line on a bill rather than a piece of architecture. Check the provider's console before
   designing around the absence.
2. **Move the relay to a dual-stack host.** The relay is a 4 MB static binary with no runtime
   dependencies; it has no attachment to any particular machine.
3. **Accept IPv6-only and be explicit about it.** Legitimate for a personal tool used from networks
   you control, and worth stating plainly in the app rather than leaving users to infer it from a
   session that will not open.

Cloudflare Spectrum can proxy arbitrary TCP and UDP and would solve this, but it is priced for
enterprises and is not a reasonable line item for this product.

#### Shared IPv4 with forwarded ports

Some hosts — mikr.us among them — give you a public IPv6 address and no IPv4 of your own, but
forward a handful of ports on a shared IPv4 address. **That is enough, and it needs only two of
them**, because signalling rides Cloudflare and never touches IPv4 directly:

| Forwarded port | To | Carries |
|---|---|---|
| one TCP | the relay's control port | Control |
| one UDP | the relay's video port | Video |

**This shape needs two names**, and the reason is the one above: a hostname is either proxied or
not, and control and video cannot be proxied.

| Name | Cloudflare | Points at | Carries |
|---|---|---|---|
| `getpeering.app` | proxied | nginx | Signalling |
| `relay.getpeering.app` | **DNS only** | the shared IPv4 | Control and video |

```
PEERINGD_VIDEO_BIND=0.0.0.0:9444
PEERINGD_PUBLIC_HOST=relay.getpeering.app
```

**The forwarded port need not match the bound one**, and it usually does not on a shared address —
the host picks both. Only the outside number is reachable, so tell the relay which it is:

```
PEERINGD_CONTROL_ADDR=[::]:9443
PEERINGD_PUBLIC_CONTROL_PORT=51234    # what mikr.us forwards to 9443

PEERINGD_PUBLIC_VIDEO_PORT=51235      # what mikr.us forwards to 9444
```

Both default to the bound port, so they are only needed when the two differ. Check the forwarding
panel before assuming; getting it wrong produces clients that are told to connect to a port that
nothing answers on, which looks exactly like the relay being down.

**One forwarded UDP port is now enough for any number of sessions.** That is the point of the
per-datagram prefix: every session shares the socket, so the number of ports you can forward stopped
being the number of people who can connect at once. It used to be a real ceiling — a host that could
forward one UDP port could carry one concurrent session, and the relay refused the rest rather than
letting two sessions interfere.

A reconnect
supersedes the previous session and takes the port straight back, rather than waiting for it to
expire — which is the behaviour a one-port range depends on, and which is why a session's video
task stops the moment it is superseded.

#### Firewall

Open exactly the ports in use and nothing else:

```sh
# shape A
ufw allow 8443/tcp && ufw allow 9443/tcp && ufw allow 9444/udp
# shape B
ufw allow 443/tcp  && ufw allow 9443/tcp && ufw allow 9444/udp
```

One UDP port, not a range. It is the port in `PEERINGD_VIDEO_BIND`, and the startup log prints
it — every session shares it, so the firewall rule does not change as sessions come and go.

#### Unit, and updating

The unit is in the repository, at `deploy/peeringd.service`, so what is running on a box can be
diffed against what the code expects rather than reconstructed from a snippet in a README. **The
deploy script installs it**, with the binary, and that is the point: this file used to describe a
machine that did not exist, and nobody found out until installing it took the relay down.

```sh
# Once, on a new machine.
sudo install -m 644 deploy/peeringd.service /etc/systemd/system/peeringd.service
sudo install -m 600 /dev/null /etc/peeringd.env    # then fill it in from the table above
sudo systemctl daemon-reload
sudo systemctl enable --now peeringd
```

**Three things the instructions above used to say, and should not.** They are written down because
each one was believed and acted on, and each one stops the service:

- **No `useradd`.** The relay runs as root, and the unit says why. It terminates signalling TLS with
  the Let's Encrypt certificate, whose key is mode 600 owned by root; a service user would need read
  access to it, so the choice is between loosening the key and not dropping the privilege. There is
  no `peeringd` user on any box this runs on.
- **No `/opt/peeringd`.** There is no such directory, and the unit has no `WorkingDirectory=`. The
  site root in the environment file is absolute, so nothing depends on the working directory.
- **`/etc/peeringd.env`, not `/etc/peeringd/peeringd.env`.** A file, not a directory inside one.
  `EnvironmentFile=` is not tolerant of a missing path: systemd refuses to start the unit and the
  journal says `Failed to load environment files`. That is worth knowing before editing this line.

`Environment=` lines go in that file, which keeps the unit readable and the settings greppable.
There is no `AmbientCapabilities=` in the unit: it was there for a listener on 443, which these
boxes do not have, because nginx owns 443 and proxies to the relay. A setting that is wrong about
the machine is worse than no setting, and `CapabilityBoundingSet=` beside it would have taken every
capability away from a process that was otherwise root.

**`enable` is half the command, and it is the half that is easy to skip.** A unit that was
`start`ed but never `enable`d runs until the machine reboots and then simply does not come back.
That, or a unit that failed repeatedly and hit systemd's start limit, is the usual explanation for
a relay that is up in your memory and down in reality.

**When the relay is down, these three lines are the whole investigation:**

```sh
systemctl status peeringd          # is it running, and if not, what was the last exit
journalctl -u peeringd -n 100      # why it stopped, in its own words
systemctl reset-failed peeringd    # after fixing the cause, clear the start limit
```

#### Knowing whether it is up

The relay serves the site from the same process, so **anything that reaches the site proves the
relay is listening** — and `/healthz` exists to be pointed at:

```sh
curl -s https://getpeering.app/healthz     # ok peeringd 0.1.0
```

Point a free uptime monitor (UptimeRobot, Healthchecks, a cron job with curl and a mail command) at
that URL and check it every five minutes. It is one line of configuration and it is the difference
between learning about an outage from a monitor and learning about it from the person who tried to
connect. The endpoint reports nothing but liveness and the version: not sessions, not devices, not
load — see ``web.rs`` for why that restraint is deliberate.

**The relay also checks itself, every five minutes, from the box it runs on.**
`deploy/peeringd-healthcheck.{sh,service,timer}` install with the binary and restart the relay if
`/healthz` stops answering while the process is still alive — which is the failure `Restart=always`
cannot see, because from systemd's side the service is perfectly healthy. It retries once before
acting, and after restarting it checks *again* and says so when the restart did not help, so "it
is stuck" and "it is genuinely broken" are different lines in the journal rather than one silent
restart loop.

That covers the machine being up. It does not cover the machine being gone, the certificate
expiring, or the hostname failing to resolve — for those you still want the external monitor
above, because a box that is not running cannot tell you it is not running.

The binary is static with no runtime dependencies, so an update is a file replacement:

```sh
systemctl stop peeringd
scp peeringd-linux-x86_64 server:/usr/local/bin/peeringd
ssh server 'chmod +x /usr/local/bin/peeringd && systemctl start peeringd'
```

Restarting drops live sessions and both ends reconnect on their own — the Mac re-registers, the
phone asks again. Worth doing when nobody is mid-session anyway.

#### One limitation worth knowing

Shape B gets signalling onto 443, but **control still needs 9443**. Some corporate and hotel
networks allow only 80 and 443 outbound, so the app will find the Mac and then fail to open the
control connection. Cellular and home networks are unaffected, which covers the intended use, but
it is a real edge and worth recognising from the symptom rather than debugging from scratch.

Bandwidth is the only real running cost: see the note below.

## The wire contract

Everything below is what the Swift side implements. Hex means lowercase hex of 16 raw bytes.

### Signalling — WebSocket, JSON

A **Mac** sends `registerHost` and then simply holds the socket open. Holding it open *is* its
presence: there is no heartbeat and no roster, so a Mac that drops is offline the moment the socket
closes, and re-registers when it comes back — on a new address, under the same device ID.

```jsonc
// Mac → relay
{"type":"registerHost","deviceId":"…","name":"Studio","protocolVersion":3}
// relay → Mac
{"type":"registered","sessionTtlSeconds":300}

// phone → relay
{"type":"connectToHost","hostId":"…","clientId":"…","protocolVersion":3,"plan":"free","jwsRepresentation":"eyJ…"}
```

`clientId` is the phone's own device ID. The relay wants it only to recognise a reconnecting phone
and supersede its previous session rather than accumulate one per attempt.

`plan` is `free`, `relay`, `plus` or `pro`. It is what the meter is set by only when
`PEERINGD_TRUST_CLAIMED_PLANS` has been turned on, or when `jwsRepresentation` is present and
verifies: see "Plans, and what the relay does not check" above for the receipt check, the switch,
and what happens to everything unrecognised. `apiKey` is optional and rarely present: a key in the
server's own list grants unlimited relay regardless of the plan.

Both ends then receive a session. **This is the one message the two ends do not receive
identically** — the `videoToken` differs, for the reason given under video below.

```jsonc
{"type":"sessionReady","controlHost":"…","controlPort":9443,"videoHost":"…","videoPort":51234,
 "controlToken":"…","videoToken":"…"}
```

The Mac receives it unsolicited — it never asked for this, and a phone may connect to it at any
time. If the Mac is not registered, the phone gets:

```jsonc
{"type":"hostOffline","deviceId":"…"}
```

`{"type":"ping"}` keeps an idle socket alive through NAT timeouts and is answered with
`{"type":"pong"}`. Anything unparseable is answered with `{"type":"error","code":…,"message":…}`.

### Control — TCP

Connect to `controlHost:controlPort`, write the **16 raw bytes** `unhex(controlToken)` with no
framing and no newline, then start TLS immediately. The relay consumes exactly those 16 bytes and
splices the rest to the peer verbatim; everything after them belongs to the two ends.

The token is single-use and is spent when the splice it paid for finishes. It travels in the clear
because it has to: it is what tells the relay where to carry the handshake, so it necessarily
precedes it. Stealing one buys an attacker a connection that fails its handshake.

### Video — UDP

Every datagram, in both directions, begins with the sender's own `videoToken`:

```
  16 bytes                 8 bytes         n bytes          16 bytes
  unhex(videoToken)   ‖   counter   ‖   ciphertext   ‖   AEAD tag
```

The relay reads the 16-byte prefix to find the session and the slot, **strips it**, and forwards the
rest verbatim. A datagram of exactly 16 bytes — the token and nothing else — is a **bind and a
keepalive**: it registers that address with the slot and is not forwarded, which is also how a
client keeps a NAT binding open across a quiet spell. Anything from an unbound address, or carrying
an unknown token, is dropped **without a reply**, so a prober learns nothing about whether a session
exists.

**Each end has a different token, and that is still load-bearing.** With one shared token the relay
could not tell which slot a re-bind belonged to, so a phone whose carrier NAT moved it mid-session
would be indistinguishable from a stranger taking a slot, and slot assignment would depend on which
packet happened to arrive first. Two tokens fix the mapping — slot 0 is always the phone, slot 1 is
always the Mac — and make re-binding work: the next datagram from the new address moves the slot and
the peer follows.

**What the prefix costs, and what it buys.** Sixteen bytes per datagram, and the relay can now see
which session a packet belongs to and where it sits in the sequence. What it buys is that the port
count stops being the session count: one forwarded UDP port carries every session on the host,
where a per-session socket needed a port each — and a shared-IPv4 VPS gives you about seven. The
payload is sealed with a key the two ends derive from a secret exchanged inside the control
session, so the relay forwards ciphertext it cannot read and never sees a nonce it could forge.

## Cost

Bandwidth is the only real cost, and at this scale it is small. Relayed 1080p video is roughly
2.25 GB per hour at 5 Mbps, and a €5/month VPS typically includes tens of terabytes.

**The hardware is not the constraint, and a capacity estimate should start from bandwidth.** There
is one UDP socket for the whole process, not one per session — every session is demultiplexed by the
sixteen-byte prefix — so video costs no file descriptors at all. What a session costs is two file
descriptors for its control splice and about a megabyte of kernel socket buffers; what it costs in
CPU is a `recv_from`, a table lookup and a `send_to` per datagram, with no crypto on this side
because the payload is sealed. A session that walks away without disconnecting is still worth
reaping, and `PEERINGD_SESSION_TTL` is what does it — but it bounds memory and sockets, not the
thing that actually runs out first, which is the traffic allowance.

**A session can be created by anyone, so there is a ceiling on them.** Asking is unauthenticated
and costs the asker nothing: a loop over `ConnectToHost` with a different client id each time used
to insert a session and two video routes per message, with nothing bounding the total and nothing
releasing it when the socket closed, only the sweep and its five-minute TTL. `PEERINGD_MAX_SESSIONS`
is the answer to that, and `PEERINGD_MAX_CONNECTIONS` bounds the sockets the requests arrive on. A
thousand sessions is several times what a machine with a shared gigabit uplink could ever carry, so
the number is a backstop rather than a limit anybody meets on purpose. Raise it on a bigger link:
the cost per session is the two lines above.
