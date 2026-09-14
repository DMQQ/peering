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
cargo test                      # 30 unit tests and 5 end-to-end socket tests
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

**The relay is not an HTTP service, and only one of its three listeners can be proxied.**
Signalling is a WebSocket and nginx can front it. Control is a raw TCP splice carrying a TLS session
belonging to the two ends — nginx's `sites-enabled` cannot proxy it, and neither can anything else
that expects HTTP. Video is UDP. So the shape depends on whether the machine already serves HTTPS.

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
| `peering.dmqq.dev` | Proxied (orange) | Signalling only. Cloudflare → nginx → the relay's loopback listener |
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

**A grey-cloud name pointing only at IPv6 will not work for IPv4-only clients.** Cloudflare's proxy
hides that for HTTP — it terminates the connection and reaches your origin however it can — but
control and video go straight to the origin, so a client on an IPv4-only network simply cannot reach
them. Polish fixed-line and much of mobile is IPv6-reachable, so this may be fine in practice, but
it is the thing to know before wondering why one particular network never connects. An `A` record
alongside the `AAAA` removes the question entirely.

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

```ini
[Unit]
Description=Peering relay
After=network-online.target

[Service]
ExecStart=/usr/local/bin/peeringd
EnvironmentFile=/etc/peeringd.env
Environment=RUST_LOG=info
Restart=always
User=peering

[Install]
WantedBy=multi-user.target
```

`Environment=` lines go in `/etc/peeringd.env`, which keeps the unit readable and the settings
greppable. Binding 443 directly needs `AmbientCapabilities=CAP_NET_BIND_SERVICE`; shape B does not,
since nginx owns that port.

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
{"type":"connectToHost","hostId":"…","clientId":"…","protocolVersion":3}
```

`clientId` is the phone's own device ID. The relay wants it only to recognise a reconnecting phone
and supersede its previous session rather than accumulate one per attempt.

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
