# Handoff: a direct path between the two ends

**Why.** Every relayed session detours through one Hetzner box in Helsinki. For two ends in the same
city that is ~100 ms of avoidable latency; for a US user reaching a US Mac it is ~200–400 ms, and
6–10× worse than a direct path would be. The relay is doing NAT traversal the expensive way — by
being the meeting point for *all* the traffic — when the cheap way is to use it only as an
introduction.

**What landed (2026-09-19).** The relay can now introduce the two ends, and the Swift side can ask
for and decode the introduction. Nothing yet *uses* it, so no behaviour has changed.

## Done, and tested

| Where | What |
|---|---|
| `Relay/src/protocol.rs` | `requestPeerAddress` (client → relay) and `peerAddress` (relay → client, `host` + `port`) |
| `Relay/src/session.rs` | `VideoRoutes::peer_address(token)` — a read-only lookup of the *peer's* observed source address |
| `Relay/src/signalling.rs` | dispatch for the new message; `peerAddressUnknown` when the peer has not been heard from |
| `RemoteCore/RelayProtocol.swift` | `RelayPeerAddress`, the two new wire messages, hex encoding of the token |
| `RemoteCore/RelaySignalling.swift` | `discoverPeer(at:videoToken:attempts:interval:)` — asks until answered, one connection for the whole conversation |

Tests: `cargo test` in `Relay/` (144, including a new end-to-end test that opens a real session over
a real WebSocket and asserts each end is told the other's address) and `swift test` in `RemoteCore/`
(281). Both green.

Design notes worth keeping:

- **The ask is identified by the asker's own video token**, which is the only thing either end holds
  that says which of the session's two slots it is. Nothing new is collected to answer it — the relay
  already stores each slot's observed address, because forwarding is impossible without it.
- **The answer is an observation, not a promise.** A NAT that forwards to the relay need not accept
  anything from a third party. The relay cannot know, so it says where the peer *was* and the two
  ends settle the rest by trying.
- **`peerAddressUnknown` is the ordinary first answer**, not a failure: a client asks before it has
  sent a datagram, so the peer has usually not been heard from yet. `discoverPeer` asks again.
- `lib.rs` and `README.md` both state "neither end ever learns the other's address" as a deliberate
  property. That is now false and those two lines should be updated rather than left to mislead.

## The blocker, found the hard way

`VideoDatagramSocket` (`RemoteCore/VideoDatagram.swift:393`) is built on
`NWConnection(to: .hostPort(relayHost, videoPort), using: .udp)` — **a connected UDP socket**. Two
consequences, and together they are the whole of the remaining work:

1. **It only receives from the relay.** A connected UDP socket drops datagrams from any other
   source, so a Mac sending straight to the phone would have its picture discarded by the phone's own
   socket, silently.
2. **The address the relay reports belongs to that socket's local port.** A UDP NAT mapping is per
   local port, so opening a second socket to talk to the peer creates a *different* mapping — one the
   peer has never been told about and cannot reach. The peer's address is only useful to the socket
   that earned it.

So the transport has to become one local port that can send to **two** destinations and receive from
**both**. That is the change; everything else is bookkeeping.

## The design the rest should follow

**Do not invent a second crypto path.** The datagram lane already seals arbitrary `MessageKind`s
(`VideoDatagramSealer.seal(kind:payload:)`) and opens to arbitrary `Frame`s, keyed by a per-session
secret the Mac grants over the control channel and split per direction by `VideoKeySchedule`. A
direct datagram is byte-for-byte what the relay would have delivered — `[counter][ciphertext][tag]`,
no prefix — so:

- **the receiver needs no change at all** to *open* a direct datagram;
- **the AEAD open is the path's proof.** A datagram that decrypts under the session key with a fresh
  counter is authentically from the peer. That is stronger than a nonce echo, and it costs nothing
  because the sealer already exists.

**The liveness decision needs no new control messages.** The host's video socket sees the *source
address* of everything that arrives. A datagram from the peer's address rather than the relay's is
the whole signal:

- each end sends sealed probes to the peer's reported address, from the socket that earned it;
- the host, on seeing probes arrive from the peer, moves its video sending to that address — no
  prefix, no relay;
- it reverts to the relay when the probes stop. That heuristic is local to the host, needs no
  version bump, and its failure mode is exactly today's behaviour.

## Ordered work

1. **`VideoDatagramSocket` → an unconnected socket with a destination.** Rework it to hold a set of
   send destinations (the relay, and optionally a peer) and to deliver `(datagram, source)` to
   `onDatagram`. Network.framework's UDP is only *connected* via `NWConnection`; an unconnected
   socket is a `NWListener`-style reader plus `send(to:)`, or a BSD socket with a `DispatchSource`.
   **This is the risky step and the one to do on its own**, with `Tools/run-probe.sh` against a real
   Mac before anything is layered on it.
2. **Probes.** A sealed, counter-consuming probe on the existing sealer, sent to the peer. The
   opener already rejects replays, so a probe cannot be replayed into the stream.
3. **Host: switch on observed source.** Track the last time a datagram arrived from the peer's
   address; send direct while that is fresh, relay otherwise.
4. **Client: the same, for the direction it sends** (input and the clipboard pull).
5. **Report the path.** `ConnectionPath` (`MacCast/SessionModel.swift:126`) gains a fourth case, and
   `SessionHistory` records it — which is what turns "did punching work?" into a number rather than
   an opinion. `AutoQualityPolicy` reads the path too, so a direct path should be allowed the higher
   bitrate sooner than a relayed one.
6. **Only then, IPv6.** With the above in place a global IPv6 address is just another candidate, and
   on an IPv6-only carrier (T-Mobile US) it needs no punching at all. It buys nothing before step 1
   and would be untestable before step 5.

## How to test what cannot be tested here

Real hole punching needs two networks, and this machine has one. What *can* be established without
them:

- **Loopback still exercises the whole mechanism** except the NAT itself: two processes, two sockets,
  a probe that has to cross, and a switch that has to happen. `Relay/tests/end_to_end.rs` already
  runs two ends against a real relay in-process and is the pattern to copy.
- **The fallback is the thing to test hardest**, because it is what runs when the punch fails — which
  is the majority case on cellular CGNAT. Assert that a session still opens and streams when the peer
  address is never supplied, when it is supplied but refuses, and when it stops working mid-session.
- **`SessionHistory` is the field instrument.** Once step 5 lands, a week of real use says what
  fraction of connections punched, per network, without any new telemetry.

## One thing to fix on the way past

`Relay/README.md` still says "The relay holds a UDP socket per live session, so `PEERINGD_SESSION_TTL`
bounds the file descriptors that clients who walk away without disconnecting can leave behind." That
describes the superseded per-session-port design; there has been one socket for the whole process
since the token-prefix change. It misleads exactly the capacity question someone would ask next.
