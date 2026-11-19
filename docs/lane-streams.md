# Independent streams on the datagram lane

## Problem

While the direct path is live, the control connection's TLS bytes ride one ordered pipe
(`ControlPipe`) over UDP. Everything shares that one ordered stream: input, pings, clipboard,
terminals, agent chat, file transfers. One lost datagram holds all of it until it is repaired,
so a file transfer can delay a keypress and a lossy link shows a ping of seconds.

## Principle (what QUIC does that this does not yet)

- Independent ordered streams. A loss stalls only the stream it was in.
- Loss recovery per stream, driven by evidence (repeated acknowledgements, a gap) before a timer.
- Priorities, so small interactive traffic is sent ahead of bulk traffic.
- One shared budget in flight, so the streams together stay a small share of the path.

Not copied: congestion control (the picture shares the path and has its own pacing), 0-RTT,
connection migration (the relay and the lane already own those), TLS 1.3 inside the transport
(the lane's AEAD already seals each datagram).

## Design

Each stream is the existing `ControlPipeSender` and `ControlPipeReceiver` pair (byte offsets,
acknowledgements, resume across carriers), carrying a sequence of ordinary `Frame`s. The message
handlers above it do not change.

| Stream | Id | Carries | Priority |
| --- | --- | --- | --- |
| interactive | 1 | commands, catalogue, notices, pointer, field state, clipboard, client state | 0 |
| pulse | 2 | ping, pong | 1 |
| terminal | 3 | terminal requests and events that are not file work | 2 |
| agent | 4 | agent and web preview requests and events | 3 |
| files | 5 | directory listing, file reads and writes, archives, file operations | 4 |

Input stays in `interactive` with the commands that change what it acts on (capture source,
space switches), because reordering a click against a source change would be a bug.

Never on a stream: the handshake and pairing, `error`, the lane's own bootstrap (`videoKeyRequest`,
`videoKey`, `videoTransport`), video and audio, and the lane-native kinds (`directProbe`,
`directCandidates`, `directCommand`, `controlPipe`).

Wire: a new `MessageKind.stream`. Payload is one stream id byte, then a `ControlPipeFrame`
(`data(offset, bytes)` or `ack(upTo)`). One stream frame fits one sealed datagram.

Carriers, as the pipe has them:
- the sealed datagram lane while it is live (lossy: retransmit, at most 32 000 bytes in flight
  across all streams, lowest priority stream starved first);
- otherwise the TLS control connection (reliable: large pieces, no retransmit), carrying the same
  stream frames as `MessageKind.stream` frames.

A carrier change resumes each stream from its last acknowledged offset, as the pipe does now.
Three consecutive timeouts on the lane ban it for ten seconds, as the pipe does now.

Negotiation: `ClientHello.supportsStreams` and `ServerHello.supportsStreams`, both optional. The
mux is used only when both are true, so a peer that does not implement it (the Android and Windows
apps until they do) keeps the plain frame protocol. Streams start at `ready`.

When the mux is in use the TLS control connection no longer rides the datagram lane
(`ControlPipeSplice.attachDirect` is not called), so no ordered stream lives on UDP any more.

## Work, in order

1. Engine (RemoteCore, no wiring): `MessageKind.stream`, `StreamID`, `StreamFrame` wire,
   `StreamClass` routing of a `Frame` to a stream, `StreamMux` (per stream sender and receiver,
   priority scheduling, shared budget, carrier choice, frame decoding per stream).
   Tests: wire round trip, routing table, independence under loss, priority, shared budget,
   carrier switching in both directions, interleaved streams decode to the original frames.
2. Negotiation and client wiring: the two hello flags, `ClientConnection` routes `send(_ frame:)`
   through the mux once active, `ClientSession` feeds `.stream` frames and lane datagrams in.
3. Host wiring: `PeerConnection` routes sends, `HostSession` feeds `.stream` frames, the lane
   hands `.stream` datagrams to the mux and sends the mux's datagrams.
4. Retire the TLS pipe's direct carrier when the mux is active; remove what becomes dead.
5. Verify: every package's tests, build both apps (Debug), install, read the Mac log and the
   phone log under loss.

## Done means

- A transfer in `files` does not delay `interactive` or `pulse` (test, not claim).
- Loss in one stream leaves the others' delivery times unchanged (test).
- A peer without `supportsStreams` still connects and works.
- The ping shown is the `pulse` stream's, so it no longer includes other traffic's repairs.

## Not in this change

Android and Windows implementations; a separate stream for the clipboard images; congestion
control; moving video chunks onto streams.
