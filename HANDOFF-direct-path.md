# A direct path between the two ends

**Why.** Every relayed session detours through one Hetzner box in Helsinki. For two ends in the same
city that is ~100 ms of avoidable latency; for a US user reaching a US Mac it is ~200–400 ms, six to
ten times what a direct path costs. The relay was doing NAT traversal the expensive way — by being
the meeting point for *all* the traffic — when the cheap way is to use it only as an introduction.

**It is built.** A relayed session now tries a path straight between the two ends and keeps the relay
as its fallback. Default on, no setting, and the failure mode is exactly the behaviour that existed
before.

## What happens on a session now

1. Both ends open their video datagram socket and bind to the relay, as they always did.
2. The Mac grants the video secret over the control channel; the client builds its openers.
3. **Both ends ask the relay where the other is** (`requestPeerAddress` → `peerAddress`) and point
   their socket at the answer.
4. **Both ends probe it**, sealing a `.directProbe` datagram each time so the receiver can tell a
   real one from a forged source address by opening it with the session key.
5. The Mac takes the address a probe arrives *from* as where to send the picture, and its socket
   starts sending straight there — no relay token, because the token is the relay's addressing and
   nothing else.
6. The client sees the picture arrive from something that is not the relay and reports the change.
7. If the probes stop — a NAT mapping expiring, a network moving — the socket reverts to the relay
   by itself after `directPathIdleTimeout`, and the slow probe phase keeps trying to get it back.

## Done, and tested

| Where | What |
|---|---|
| `Relay/src/protocol.rs` | `requestPeerAddress` / `peerAddress` |
| `Relay/src/session.rs` | `VideoRoutes::peer_address` — a read-only lookup of the *peer's* observed address |
| `Relay/src/signalling.rs` | dispatch; `peerAddressUnknown` while the peer has not been heard from |
| `RemoteCore/VideoDatagram.swift` | **the socket rewritten**: one local port, two destinations, source-aware delivery |
| `RemoteCore/ClientSession.swift` | discovers the peer, probes it, reports the path |
| `MacCastHost/Video/VideoDatagramLane.swift` | probes back, and switches what it sends on the address a probe came from |
| `MacCast/SessionModel+Events.swift` | records the path change |

Tests: `cargo test` in `Relay/` (**144**), `swift test` in `RemoteCore/` (**287**). All green. The iOS
app and the host both build.

## The four decisions worth keeping

**The socket had to stop being connected.** It was an `NWConnection` to the relay, and a connected UDP
socket cannot send to a second address *or* receive from one — the Mac's picture would have been
discarded by the phone's own socket, silently. A UDP NAT mapping is also per local port, so the
address the relay reports is only usable by the socket that earned it: the socket that talks to the
relay had to become the socket that talks to the peer. It is now a BSD socket, which is also why it
is finally testable — 6 of the new tests drive it on loopback.

**Anyone not the relay is a peer.** Classification is by *not being the relay*, not by matching a
known address — the Mac cannot know the phone's address until a datagram arrives from it, so a rule
requiring it first could never learn it. That makes `.peer` a fact about addressing, not identity,
which is why the open is what decides whether to trust it.

**The AEAD open is the path's proof.** A probe that opens under the session key came from the peer; a
forgery fails to open and changes nothing. No new crypto, no nonce echo, no acknowledgement.

**Both ends knock.** A NAT that *maps* a port is not a NAT that *admits* traffic — the common kinds
admit a packet from an address only once the machine has sent to that address. One-sided probing
opens on the permissive NATs and fails silently on the rest, which is the worst kind of networking
bug because it works on the developer's machine.

## What is left

1. **Record the path where the numbers live.** `ConnectionPath` (`MacCast/SessionModel.swift:126`)
   should gain a case and `SessionHistory` should record it, so "did punching work, and how often"
   becomes a number rather than an opinion. `SessionModel.usedDirectPath` is already set and is the
   value to record — but do **not** fold it into `connectionPath`: the relay meters by how long it
   splices a session whether or not the picture went around it, so moving the connection path off
   `.relay` would make `relaySecondsUsedThisPeriod` stop counting a session the relay is still
   charging for.
2. **Let `AutoQualityPolicy` read it.** A direct path is not a relay path and should be allowed the
   higher bitrate sooner; today it is judged by `connectionPath`, which is still `.relay`.
3. **IPv6.** Now cheap: a global v6 address is just another candidate, and on an IPv6-only carrier
   (T-Mobile US) it needs no punching past the firewall. It was worth nothing before step 1.
4. **Reconsider the US relay.** With punching live, a US region is a fallback for the sessions that
   cannot punch rather than the fix for latency. Decide it from step 1's numbers.

## How to test what cannot be tested here

Real hole punching needs two networks and this machine has one. What is established:

- **Loopback exercises everything but the NAT**: `VideoDatagramSocketTests` opens a real socket, sends
  to a real address, receives from a second one, and asserts the move from relay to peer — including
  that the relay stops being used once the peer has spoken.
- **The relay end to end**: `Relay/tests/end_to_end.rs` opens a real session over a real WebSocket and
  asserts each end is told the other's address, and that asking early returns a recoverable
  `peerAddressUnknown` rather than failing.
- **The fallback is the thing to test hardest in the field**, because it is what runs when the punch
  fails — the majority case on cellular CGNAT. It is the "nothing arrives from the peer" path, and
  the socket reverting to `.relay` is already covered.

## Corrected on the way past

`Relay/README.md` and `Relay/src/lib.rs` both claimed *"neither end ever learns the other's address"*.
That was true and is not any more; both now say what is actually still guaranteed — that the relay
cannot *read* what it carries. The README's capacity section also described a UDP socket per live
session, superseded since the token prefix, which misled exactly the sizing question someone would
ask next.
