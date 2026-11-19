# One QUIC connection on every path

Status (2026-11-19, branch `quic`): stages 1 to 3 done. The spike passed on a phone (LAN: 94 ms
handshake, 12 ms stream round trip, 225 Mbit/s of datagrams at 99.7 %); relayed sessions run over
one QUIC connection and were tried on a device (picture, pointer, sound). Pending: the relay change
for liveness and metering of UDP-only sessions, then stage 4. Replaces `docs/lane-streams.md`.

## Why

Today a session is built from four transports: LAN TLS over TCP, relay TLS over TCP, the relay's
UDP datagram lane, and the direct (hole-punched) UDP path. Each fix has been for one combination of
them, and a change of path tears the session down and builds a new one. The results the user sees:

- a 2 to 3 second gap (picture and sound) when the phone moves between LAN, relay and direct;
- control traffic stalling behind one lost TCP segment on the relay;
- picture and sound queueing behind each other on whichever connection carries both;
- sessions dropping during path changes, with several layers each guessing at liveness.

The cure is one connection that owns reliability, ordering, priorities, congestion control and
path changes, on every path. That is QUIC. We use a real implementation rather than finishing our
own: the parts we keep hand-building (loss recovery, migration, congestion control) are exactly the
parts where hand-built versions keep needing patches.

## Library: quiche (Cloudflare)

- **Sans-IO.** quiche never opens a socket. We feed it received packets and send what it hands
  back, on our own socket. That keeps three things we need:
  - the relay's routing token in front of every datagram (the relay forwards by it, see
    `relay/src/udp_relay.rs`), added and stripped by us;
  - the hole-punched socket: the direct path is the same UDP socket that knocked, so the NAT mapping
    the punch made is the one QUIC uses;
  - a TCP fallback carrying the same QUIC packets length-prefixed, for networks that block UDP.
- **One implementation everywhere.** Rust crate for the Windows host and the relay's tests, a C API
  for Swift (iOS, macOS) and for Kotlin through JNI (Android).
- **Has what we use:** streams with priorities (RFC 9218 urgency), unreliable datagrams (RFC 9221),
  path probing and connection migration, BBR and CUBIC congestion control.

Considered and rejected:
- **Apple's Network framework QUIC.** It opens its own socket, so it cannot add the relay's token
  and cannot reuse the punched socket; the relay would have to route by address or connection id,
  and Android and Windows would still need another library. Two QUIC stacks to keep in step.
- **quinn.** Good, but its sans-IO layer has no C API, so Swift and Kotlin would need a binding we
  write and maintain.

## What a session becomes

One QUIC connection per session, the phone as client, the Mac (or Windows host) as server.

**Identity.** TLS 1.3 inside QUIC, with the keys we already pin. quiche verifies nothing itself
(`verify_peer(false)`); once the handshake is done each end reads the peer certificate and checks it
against the pin, exactly as the TLS connections do now. Pairing (commit, reveal, SAS) runs as the
first stream, unchanged above the transport.

**Streams (reliable, ordered each on its own).** One QUIC stream per class, carrying today's
`Frame`s, with priorities:

| Stream | Carries | Urgency |
| --- | --- | --- |
| control | hello, pairing, commands, input that is not direct, notices, clipboard, client state | 0 |
| pulse | ping and pong (the shown ping, and liveness) | 1 |
| terminal | terminal requests and events | 3 |
| agent | agent and web preview | 4 |
| files | listing, reads, writes, archives | 6, incremental |

Ping and liveness come from one place: QUIC's own idle timeout and path validation. The app's
silence watchdogs, `verifyStillAnswering`, the LAN-gone check and the video fallback policy go.

**Datagrams (unreliable, never retransmitted).** Picture, sound and direct pointer input, each with
its own small header (kind, sequence) so loss and order are judged per kind. Sending order is a
scheduler: input, then sound, then picture. Picture keeps its parity groups, and the parity amount
keeps following measured loss. QUIC's congestion controller sets the rate; the encoder's bitrate
follows what the controller allows instead of the fixed pacer.

**Paths.**
- LAN: straight to the Mac's LAN address over UDP. Bonjour discovery is unchanged.
- Relay: the relay's UDP port, token in front. The relay does not change.
- Direct: the punched address, same socket.
- TCP fallback: the relay's TCP connection carries length-prefixed QUIC packets. Same stack, same
  streams; only slower.

A session starts on whichever path answers first (LAN if reachable, relay otherwise), then probes
the others in the background and migrates to the best one validated. A network change on the phone
is a migration, not a new session: no handshake, no new video key, no keyframe wait beyond one
asked for on the new path.

## What gets deleted

All of it goes once QUIC carries every session; nothing is kept "for old peers", because protocol
21 forces an update.

- The hand-built streams engine: `Streams/` (`StreamMux`, `StreamTransport`, `StreamRouting`,
  `StreamLaneLink`, `StreamFrame`, `StreamID`), `MessageKind.stream`, the `supportsStreams` flags.
- `ControlPipe*` and `ControlPipeSplice` (TLS over UDP).
- The datagram lane's own crypto: `VideoDatagramSealer`, `VideoDatagramOpener`'s AEAD,
  `VideoReplayWindow`, `VideoKeySchedule`, `videoKeyRequest` / `videoKey`.
- `directProbe` sealing (QUIC path validation does it).
- The separate video TCP connection and `ConnectionRole`, `VideoChunk` (control-channel video
  fallback), `videoTransport` requests and `VideoFallbackPolicy`.
- `AudioSendQueue`, the `sending` gate, the urgent send, and LAN audio on the control connection.
- The LAN TCP listener and the LAN-to-relay dial race; `LANUpgrade` becomes "probe the LAN path and
  migrate".

## Work, in order

Each stage ends with its tests passing, both Apple apps building, and the user trying it on a
device. Nothing is merged half-wired.

1. **Spike (go / no-go).** quiche built as an xcframework for iOS and macOS, a C shim, a handshake
   between phone and Mac with pinned keys, one stream and datagrams, through the relay's UDP port
   with the token, and over the direct path. Measured: handshake time, datagram rate, migration
   from relay to direct. Also checked: binary size, BoringSSL living beside swift-crypto's prefixed
   copy, App Store build. If any of these fail, we stop and decide again.
2. **`QuicSession` in RemoteCore.** Swift wrapper over the C API: socket I/O, timers, streams as
   frame channels, datagrams, path list, migration. Tests run sans-IO against a simulated network
   with loss, reordering, delay and an address change, with no sleeps.
3. **Client and host on QUIC, relay path only.** Handshake, pairing and every stream above;
   picture and sound as datagrams. The old relay transports still exist but are not used by a
   protocol 21 pair.
4. **All paths.** LAN over UDP, direct, TCP fallback, migration between them, and the app's path
   indicator driven by the migrated path.
5. **Congestion-driven quality.** Encoder bitrate from the controller, parity from loss.
6. **Delete** everything in the list above, and update `AGENTS.md`.
7. **Windows host** on the quiche crate.
8. **Android client** on quiche through JNI.
9. **Telemetry.** `session_started` / `session_ended` gain time per path (lan, relay, direct, tcp
   fallback) and migration counts, so PostHog shows how devices actually connect.

## Done means

- Turning Wi-Fi on or off mid-session changes path with no new session and no gap in sound longer
  than one round trip on the new path (measured from the device logs, not judged by ear).
- A file transfer does not delay input, ping or sound (test with the simulated network).
- Loss on one stream does not delay another (test).
- Picture and sound never wait on each other (test).
- The relay's UDP code is unchanged; its TCP code only carries the fallback.

## Risks

- **FFI and memory.** A C API across Swift and Kotlin; every buffer's ownership is explicit and
  tested.
- **Battery and CPU on the phone** from userspace QUIC at video rates. Measured in the spike.
- **Networks that throttle UDP.** The TCP fallback covers blocking; throttling shows as loss and the
  controller backs off.
- **Size of the change.** Stages 3 to 6 touch every connection path. Each stage ships working, and
  the user tests each one before the next starts.
