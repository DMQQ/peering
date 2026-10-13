# Video and audio lanes

Part of the [protocol](../protocol.md). Sources: `VideoWire.swift`, `VideoDatagram*.swift`, `VideoKeySchedule.swift`,
`VideoFallback.swift`, `VideoReplayWindow.swift`, `ClientSession+Video*.swift`, `ClientSession+DirectPath.swift`.

## 1. Configuration and frames

`videoConfig` (0x09) JSON `VideoStreamConfig`: `sourceID` (string), `codec` (`"h264"` or `"hevc"`), `pixelWidth`,
`pixelHeight` (encoded pixels), `parameterSets` (array of base64 `Data`): SPS then PPS for H.264; VPS, SPS, PPS for
HEVC. It is sent when the description changes, never per frame; a client MUST rebuild its decoder on every one it
receives and a host MUST NOT repeat an unchanged one (`VideoWire.swift:37-60`). A client that joins mid-stream gets a
config and a keyframe.

`videoFrame` (0x0A) payload, all integers big endian (`VideoWire.swift:113-164`):

```
u8  flags            bit 0 = keyframe
u32 pixelWidth
u32 pixelHeight
i64 presentationValue
i32 presentationTimescale
u32 dataLength       MUST equal the remaining bytes
... data             H.264 or HEVC in AVCC form: NAL units each prefixed by a 4 byte big endian length
```

Header size is 25. Parameter sets are never in `data`. B-frames are not used (no reordering), so decode order equals
presentation order. A frame whose length field disagrees with the payload MUST be rejected.

Converting to Annex-B for a platform decoder: replace each 4 byte length with `00 00 00 01`. Converting an encoder's
Annex-B output to AVCC: split on start codes (3 or 4 bytes), prefix each NAL with its length as 4 bytes, lift SPS and
PPS (H.264 NAL types 7, 8; HEVC 32, 33, 34) into `parameterSets`, and drop them from `data` (a keyframe still decodes
because the client has the config).

Audio: `audioConfig` (0x13) `{codec:"pcmFloat32", sampleRate:Double, channelCount:Int}`. `audioFrame` (0x14) payload:
`u32 sampleCount, u32 channelCount, i64 ptsValue, i32 ptsTimescale` (20 bytes) then `sampleCount * channelCount` samples of native `Float` bytes, interleaved. UNVERIFIED: byte order is not stated in
the source; every Apple Mac is little endian, so treat them as IEEE 754 little endian. The Windows host writes little endian too, and sends 48000 Hz, 2 channels, 960 samples (20 ms) a frame. `channelCount` MUST be 1 to 32 and the length MUST match.

Video is droppable and keyframes are not: when a frame is waiting and a newer one arrives, a keyframe always wins, and
an undelivered keyframe is never replaced by a delta (`VideoDropPolicy`, `VideoWire.swift:299-313`).

Encoder behaviour the Mac host has (a host need not match it exactly): low latency rate control, no B-frames, a
keyframe at least every 2 s and immediately for a new client, resume or source switch, default bitrate
`clamp(width * height * 0.12 * fps, 4 Mbps, 30 Mbps)`, 60 fps default.

## 2. Lanes

* Primary on LAN: the second TCP connection (role 2) carries `videoConfig`, `videoFrame` and audio frames.
* Primary when relayed: the UDP lane of section 3.
* Control lane: the same messages cut into `videoChunk` frames on the control connection (section 5).

## 3. UDP lane

Used on relayed sessions, and on a direct path once it opens. One unconnected UDP socket per end is used for the relay and
for the direct peer.

Key: after ready, the client sends `videoKeyRequest` (0x19, empty) on the control connection. The host answers `videoKey`
(0x1A) `{"secret":"<base64 of 32 random bytes>"}` on the same TLS stream, so the relay never sees it
(`ClientSession+Video.swift:97,121-139`). Per direction keys:

```
key(direction) = HKDF-SHA256(ikm = secret, salt = "pl.dmq.peering.video-datagram", info = label, L = 32)
label = "video client-to-host"  for datagrams the client sends
label = "video host-to-client"  for datagrams the host sends
```

Datagram as sent (`VideoDatagramSealer.swift:25-60`):

```
token (16 bytes, the sender's video token)  || counter (u64 BE, starts at 1, +1 per datagram) || ciphertext || tag (16)
ChaCha20-Poly1305, key = direction key, nonce = 00 00 00 00 || counter (12 bytes), no associated data
plaintext = one complete frame (u32 length, kind, payload), which is either a whole message or one videoChunk
```

The relay strips the 16 byte token, so the receiver sees `counter || ciphertext || tag`. A datagram that is only the
16 byte token is a bind: the relay records the sender's address and forwards nothing. Both ends send a bind on start and
repeat it as a keepalive. Total datagram size is at most 2048; chunks are sized so a sealed datagram is about 1080 bytes.

Receiver (`VideoDatagramOpener.swift`): reject if shorter than 24 bytes or longer than 2048; read the counter; check the
replay window without changing it; open; only then commit the counter; decode the frame; if the kind is `videoChunk`,
feed a per-lane reassembler. Each lane has its own opener and reassembler; sharing one across lanes drops pictures.

Replay window (`VideoReplayWindow.swift`): 64 entries. Accept any first counter. A counter above the highest is accepted;
below, it is accepted only if the distance is under 64 and its bit is not set. Committing a higher counter shifts the
bitmap (a shift of 64 or more clears it) and sets bit 0.

## 4. Direct path

The client asks the relay `requestPeerAddress{videoToken}` (its own token) and receives the host's observed address, or
the error `peerAddressUnknown` (retry). It then sends sealed `directProbe` (0x1B, empty) datagrams to that address every
250 ms for 12 attempts and every 5 s afterwards, re-asking the relay every 12 attempts. The host does the same toward the
client's address. A probe that authenticates proves the source address; each end then sends video to the source of the
latest authenticated datagram it received. Lane pings (`ping` sealed on the lane, answered with `pong`) measure the path.

## 5. Control channel fallback

`videoChunk` (0x17) payload: `u8 innerKind, u32 frameID, u16 index, u16 count` (9 bytes) then up to 16384 bytes
(1024 on the UDP lane) of the inner payload. The inner message is a `videoConfig`, `videoFrame` or audio frame. A chunk
with a newer `frameID` discards the frame in progress; `count` MUST be 1..65535 with `index < count`; a chunk whose
inner kind or count contradicts the frame in progress is ignored; nested chunks are rejected; reassembly is capped at
4 MiB (`VideoFallback.swift:41-180`).

Client policy (`VideoFallbackPolicy`, `VideoFallback.swift:183-282`), with `now` monotonic:

* Applies only to a relayed session. Not in fallback: if no picture for 3 s and a pong arrived within the last 5 s and
  the last request is older than 5 s, send `videoTransport{control}` and enter fallback.
* In fallback: after 5 s and two pictures seen on the primary lane, send `videoTransport{primary}` and leave fallback.
  Otherwise, if no picture arrived since the last request and 5 s passed, repeat the control request.
* While in fallback the client stops asking for more than the low tier (2000 kbps).

Host policy: it MAY decline a request when it has produced nothing recently (a still screen and a blocked path look the
same to it). While serving the control lane it caps the rate at 2000 kbps and keeps sending keyframes on the primary lane
every 4 s so the client can see recovery.

There is no message for a client to request a keyframe. Loss on the UDP lane therefore costs a picture until the next
keyframe (at most 2 s); pausing and resuming the picture (`setVideoEnabled`) forces one.
