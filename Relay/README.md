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

Three ports, and only the first needs to be memorable:

| Port | Protocol | What |
|---|---|---|
| 443 | TCP | Signalling. 443 rather than something free, because it is the one port guest and corporate networks never block |
| 9443 | TCP | Control relay |
| 40000–40100 | UDP | Video, one port per live session |

**DNS** — an `A` record for the relay host pointing at the server. Add an `AAAA` too if it has IPv6,
and check which the clients actually pick, because a broken IPv6 route shows up as a connection
that hangs rather than one that fails.

**Firewall** — open exactly the three above and nothing else. The video rule can only be written
once `PEERINGD_VIDEO_PORTS` is set.

```sh
certbot certonly --standalone -d peering.dmqq.dev
```

```ini
[Unit]
Description=Peering relay
After=network-online.target

[Service]
ExecStart=/usr/local/bin/peeringd
Environment=PEERINGD_SIGNAL_ADDR=0.0.0.0:443
Environment=PEERINGD_CONTROL_ADDR=0.0.0.0:9443
Environment=PEERINGD_VIDEO_PORTS=40000-40100
Environment=PEERINGD_TLS_CERT=/etc/letsencrypt/live/peering.dmqq.dev/fullchain.pem
Environment=PEERINGD_TLS_KEY=/etc/letsencrypt/live/peering.dmqq.dev/privkey.pem
Environment=RUST_LOG=info
Restart=always
# Binding 443 as a non-root user needs this, and it is narrower than running the relay as root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
User=peering

[Install]
WantedBy=multi-user.target
```

Only signalling needs a certificate, and only so the token exchange is not readable in transit —
the media is encrypted end to end regardless and does not depend on it. Binding 443 as a normal user
needs `CAP_NET_BIND_SERVICE`, which is preferable to running a network-facing service as root.

**Updating.** The binary is static and has no runtime dependencies, so an update is a file
replacement and a restart:

```sh
systemctl stop peeringd
scp peeringd-linux-x86_64 server:/usr/local/bin/peeringd
ssh server 'chmod +x /usr/local/bin/peeringd && systemctl start peeringd'
```

Restarting drops live sessions, and the two ends reconnect on their own — the Mac re-registers and
the phone asks again. Worth doing when nobody is mid-session anyway.

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
