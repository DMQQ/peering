# peeringd

The relay that lets a phone reach its Mac from outside the local network.

Both ends sit behind NATs that will not admit unsolicited traffic, so both connect *outward* to
this process. It introduces them, splices their control connections, and forwards their video
datagrams. Neither end ever learns the other's address, because neither end needs to — both
address the relay.

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
cargo test                      # the unit tests and 5 end-to-end socket tests
```

With no configuration it listens on all interfaces, picks a video port per session, and serves
signalling in plaintext. That is exactly right for pointing both apps at `127.0.0.1`, and never
right for a public address.

| Variable | Default | Meaning |
|---|---|---|
| `PEERINGD_SIGNAL_ADDR` | `0.0.0.0:8443` | Signalling listener |
| `PEERINGD_CONTROL_ADDR` | `0.0.0.0:9443` | Control relay listener |
| `PEERINGD_VIDEO_BIND` | `0.0.0.0:0` | Address per-session UDP sockets bind to |
| `PEERINGD_VIDEO_PORTS` | — | Range session video ports come from, e.g. `40000-40100`. **Set this anywhere with a firewall** — see below |
| `PEERINGD_TLS_CERT` | — | Certificate for signalling. Both this and the key, or neither |
| `PEERINGD_TLS_KEY` | — | Private key for signalling |
| `PEERINGD_SESSION_TTL` | `300` | Seconds a session survives without activity |
| `PEERINGD_FREE_MINUTES` | `30` | Relay minutes per device in each rolling 24-hour window for a client on the free plan. The app draws its "free relay time" bar from its own copy of this number and its own copy of the window arithmetic (`RelayPlan.allowanceSeconds`, `SessionModel.relayPeriodStart`) — change the relay and those together, or the bar lies |
| `PEERINGD_RELAY_MINUTES` | `180` | The same, for a client claiming the Relay plan. `0` turns a plan off rather than making it unlimited; Relay Plus and Pro are not metered and have no setting |
| `PEERINGD_PAID_KEYS` | — | Comma-separated API keys that bypass the quota entirely. See the note under "Plans" below |
| `PEERINGD_TRUST_CLAIMED_PLANS` | `1` | Whether a client's own statement of its plan is believed when no verifiable receipt arrives. `1` while shipped apps cannot send one; set it to `0` once the logs say nobody needs it. See "Plans" below |
| `PEERINGD_WEB_ADDR` | `127.0.0.1:8080` | Where the site is served. **Loopback by default** — see below |
| `PEERINGD_WEB_ROOT` | `site` | Directory the site is read from. Relative paths resolve against the working directory |

### Plans, and what the relay does not check

Relay time is metered per rolling 24-hour window, and how much there is depends on the plan the
client says it is on:

| Plan | Wire name | Allowance |
|---|---|---|
| Free | `free` | 30 minutes a day |
| Relay | `relay` | 3 hours a day |
| Relay Plus | `plus` | unlimited |
| Pro | `pro` | unlimited |

The client states its plan in `connectToHost` and the relay meters by it, and since 18 September it
can also hand over a **receipt**: the JWS StoreKit gives the app for its transaction, sent in the
same message as `jwsRepresentation`. When that verifies, the plan comes from the product named
inside it and the claimed `plan` is ignored. `src/storekit.rs` is the whole of the verification —
read its header before changing anything in it.

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

**A verified receipt always wins, even downward** — a Relay subscriber who sends a Relay receipt is
metered as Relay whatever their `plan` field says. Anything refused or unreadable is logged with its
reason and falls back to the claim, and a claim that is missing, unknown or malformed is the free
allowance, never unlimited. Every session line carries `plan_trust="verified"`, `"claimed"` or
`"neither"`, so which path was taken is visible in the log rather than taken on faith.

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

**The claimed plan is still trusted when no receipt arrives, and that is a deliberate transition,
not an oversight.** A shipped app cannot send a receipt it does not know how to collect, so
verification-only would drop every existing subscriber to 30 minutes a day on the day this
deployed. `PEERINGD_TRUST_CLAIMED_PLANS` (default `1`) is the switch; set it to `0` and an
unverified client is metered as free regardless of what it claims.

**Deleting the fallback is the end of the job, and the log says when.** Deploy, watch
`plan_trust="claimed"` in the session lines, and when that drops to nothing but the old builds,
set the variable to `0`. The hole it leaves open until then: a patched app can still say `pro` and
relay for nothing, exactly as before this work. What a false plan does not buy is *access* — the
relay carries a TLS session belonging to the two ends and cannot read or forge it, and a Mac is
reached only by passing its own pairing handshake — so lying buys bandwidth and nothing else.

One thing verification does **not** establish: that the receipt belongs to the device presenting
it. Nothing binds the JWS to a phone, so a receipt is a bearer token and sharing one shares the
plan until it expires. Binding it needs Apple's device-verification endpoint, which the relay
deliberately does not call — the honest description is that this stops people forging a purchase,
not that it stops them sharing one.

**`PEERINGD_PAID_KEYS` is the one grant the relay holds rather than takes on trust**, which is why
it is kept even though nothing mints a key anyone can put in it. The app generates its own UUID in
the Keychain and sends that, so the set is empty in practice and every client is metered by its
claimed plan — and a key that *is* in the set bypasses the meter whatever plan the client names.
It is honest to call this a hook rather than a feature: nothing in the app displays that UUID, and
nothing issues one, so filling the variable in today means reading the value out of the device by
some other means. Giving a device unlimited relay is what the plan field does now, and this
variable is what it would be replaced by if plans ever become verifiable.

**`PEERINGD_VIDEO_PORTS` matters more than it looks.** Unset, the OS picks each session's video
port from the whole ephemeral range — 32768 to 60999 on a default Linux — so allowing video through
a firewall means opening twenty-eight thousand UDP ports. A range of a hundred turns that into one
rule. What a closed range looks like is *control working and video never arriving*, which is a
miserable thing to debug from the symptom; the startup log prints the range that will be used so it
can be checked against the firewall directly.

The relay reports the address a client reached it on as the address to connect back to, so a
directly-addressed server needs no configuration for this. `RUST_LOG=debug` for per-connection
detail; `info` shows registrations and session allocations.

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
Environment=PEERINGD_VIDEO_PORTS=40000-40100
Environment=PEERINGD_TLS_CERT=/etc/letsencrypt/live/peering.dmqq.dev/fullchain.pem
Environment=PEERINGD_TLS_KEY=/etc/letsencrypt/live/peering.dmqq.dev/privkey.pem
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
    server_name peering.dmqq.dev;

    ssl_certificate     /etc/letsencrypt/live/peering.dmqq.dev/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/peering.dmqq.dev/privkey.pem;

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
Environment=PEERINGD_VIDEO_PORTS=40000-40100

# Required here, and the one setting that is easy to miss. Without it the relay reports the address
# each client reached it on as the place to connect for control and video — which is right when
# clients address it directly, and behind nginx is 127.0.0.1, so every client would be told to
# connect to itself.
Environment=PEERINGD_PUBLIC_HOST=peering.dmqq.dev
```

The relay's signalling listener stays on loopback; nginx is the only thing that reaches it. Control
and video are opened directly in the firewall and are **not** proxied.

#### C — the site, on the same name as signalling

`site/` in this crate is the marketing and legal site, and the relay serves it itself — see
`web.rs`. It binds `127.0.0.1:8080` by default, on the same reasoning as the signalling listener:
whatever already terminates TLS on the machine is what should face the internet.

**The two share a hostname, and that is the whole of the complication.** The app opens signalling at
`wss://peering.dmqq.dev/` — the root path — so a `location /` that serves files would swallow it. The
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
    server_name peering.dmqq.dev;

    ssl_certificate     /etc/letsencrypt/live/peering.dmqq.dev/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/peering.dmqq.dev/privkey.pem;

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
xcodebuild -project MacCast.xcodeproj -scheme MacCastHost -configuration Release \
  -archivePath /tmp/Peering.xcarchive archive

# Notarise before packaging, or every download is quarantined and the app is a dialog nobody
# finishes. This step needs an Apple ID with an app-specific password and a team.
xcrun notarytool submit /path/to/Peering.app --keychain-profile <profile> --wait
xcrun stapler staple /path/to/Peering.app

# Package and sign.
hdiutil create -volname Peering -srcfolder /path/to/Peering.app -ov -format UDZO \
  /tmp/Peering-<version>.dmg

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
| `peering.dmqq.dev` | Proxied (orange) | The site, and signalling. Cloudflare → nginx → the relay's loopback listeners |
| something like `relay.dmqq.dev` | **DNS only (grey)** | Control and video. Clients reach the server directly |

```
PEERINGD_PUBLIC_HOST=relay.dmqq.dev
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
| `peering.dmqq.dev` | proxied | nginx | Signalling |
| `relay.dmqq.dev` | **DNS only** | the shared IPv4 | Control and video |

```
PEERINGD_VIDEO_PORTS=40000-40000
PEERINGD_PUBLIC_HOST=relay.dmqq.dev
```

**The forwarded port need not match the bound one**, and it usually does not on a shared address —
the host picks both. Only the outside number is reachable, so tell the relay which it is:

```
PEERINGD_CONTROL_ADDR=[::]:9443
PEERINGD_PUBLIC_CONTROL_PORT=51234    # what mikr.us forwards to 9443

PEERINGD_PUBLIC_VIDEO_PORT=51235      # what mikr.us forwards to 40000
```

Both default to the bound port, so they are only needed when the two differ. Check the forwarding
panel before assuming; getting it wrong produces clients that are told to connect to a port that
nothing answers on, which looks exactly like the relay being down.

**The video range must be as small as the number of ports you forward** — with one forwarded UDP
port, a single-port range. The relay refuses a session when its range is exhausted rather than
quietly sharing a port, so a range wider than the forwarding is a session that cannot start rather
than two sessions that interfere.

One port is genuinely enough for this product: one phone, one Mac, one session. A reconnect
supersedes the previous session and takes the port straight back, rather than waiting for it to
expire — which is the behaviour a one-port range depends on, and which is why a session's video
task stops the moment it is superseded.

#### Firewall

Open exactly the ports in use and nothing else:

```sh
# shape A
ufw allow 8443/tcp && ufw allow 9443/tcp && ufw allow 40000:40100/udp
# shape B
ufw allow 443/tcp  && ufw allow 9443/tcp && ufw allow 40000:40100/udp
```

The video rule can only be written once `PEERINGD_VIDEO_PORTS` is set.

#### Unit, and updating

The unit is in the repository — `deploy/peeringd.service` — so what is running on a box can be
diffed against what the code expects, rather than reconstructed from a snippet in a README.

```sh
# Once, on a new machine.
sudo useradd --system --home /opt/peeringd --shell /usr/sbin/nologin peeringd
sudo install -o peeringd -g peeringd -d /opt/peeringd /etc/peeringd
sudo install -m 644 deploy/peeringd.service /etc/systemd/system/peeringd.service
sudo systemctl daemon-reload
sudo systemctl enable --now peeringd
```

`Environment=` lines go in `/etc/peeringd/peeringd.env`, which keeps the unit readable and the
settings greppable. Binding 443 directly is what `AmbientCapabilities=CAP_NET_BIND_SERVICE` in the
unit is for; shape B does not need it, since nginx owns that port.

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
curl -s https://peering.dmqq.dev/healthz     # ok peeringd 0.1.0
```

Point a free uptime monitor (UptimeRobot, Healthchecks, a cron job with curl and a mail command) at
that URL and check it every five minutes. It is one line of configuration and it is the difference
between learning about an outage from a monitor and learning about it from the person who tried to
connect. The endpoint reports nothing but liveness and the version: not sessions, not devices, not
load — see ``web.rs`` for why that restraint is deliberate.

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

`plan` is `free`, `relay`, `plus` or `pro`. It is what the meter is set by *unless*
`jwsRepresentation` is present and verifies — see "Plans, and what the relay does not check" above
for the check, the fallback, and what happens to everything unrecognised. `apiKey` is optional and
rarely present: a key in the server's own list grants unlimited relay regardless of the plan.

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

Send a bind packet to `videoHost:videoPort`:

```
  4 bytes        16 bytes
  "PBND"     ‖   unhex(videoToken)
```

Then send and receive video datagrams on the same socket. Anything from an unbound address is
dropped **without a reply**, so a prober learns nothing about whether a session exists.

**Each end has a different token, and that is load-bearing.** With one shared token the relay could
not tell which slot a re-bind belonged to, so a phone whose carrier NAT moved it mid-session would
be indistinguishable from a stranger taking a slot, and slot assignment would depend on which
packet happened to arrive first. Two tokens fix the mapping — slot 0 is always the phone, slot 1 is
always the Mac — and make re-binding work: re-send the bind packet from the new address and the
slot follows. Datagrams are otherwise opaque; the relay never looks inside one.

## Cost

Bandwidth is the only real cost, and at this scale it is small. Relayed 1080p video is roughly
2.25 GB per hour at 5 Mbps, and a €5/month VPS typically includes tens of terabytes. The relay
holds a UDP socket per live session, so `PEERINGD_SESSION_TTL` bounds the file descriptors that
clients who walk away without disconnecting can leave behind.
