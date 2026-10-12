# Peering wire protocol, version 20

This is the contract between a Peering client (phone), a Peering host (computer) and the relay. The
Swift code in `apple/RemoteCore` is the reference implementation; where this document and that code
disagree, the code wins and this file has a bug. Companion files: [protocol/video.md](protocol/video.md),
[protocol/relay.md](protocol/relay.md), [protocol/keymap.md](protocol/keymap.md), test vectors in
[protocol/vectors/](protocol/vectors/README.md).

Words: MUST and MUST NOT are used in the RFC sense. UNVERIFIED marks a shape inferred from how Swift's
synthesized `Codable` behaves and not yet confirmed by a test or a captured message.

## 1. Compatibility rules

* `protocolVersion` in both hellos MUST equal 20 (`ProtocolInfo.swift:29`). Exact equality is enforced by both
  sides (`ClientSession+Handshake.swift:38`, `HostSession+Handshake.swift:71`). Do not bump it for an addition.
* Additions are optional fields or capability flags. A feature MUST NOT be used until the peer declared it.
* Unknown JSON object keys are ignored. An unknown enum case makes the whole message fail to decode, and a failed
  decode of a control message ends the session. This is why commands that an older peer cannot decode are guarded by flags.
* A receiver MUST drop a control payload larger than 64 KiB (`maxControlPayload`, `ProtocolInfo.swift:32`) and a
  frame larger than 16 MiB. Senders are not stopped from exceeding the 64 KiB figure, so they MUST chunk.

## 2. Transport

* Host listens on TCP port 51515 (`ProtocolInfo.swift:41`). Every socket on both sides MUST set `TCP_NODELAY`.
* TLS 1.3 only, in both directions (`TLSConfig.swift:41,63`). The client is always the TLS client and the host is
  always the TLS server, including when the host dialled out to the relay.
* Mutual authentication with self-signed P-256 certificates (section 4). The TLS layer accepts any certificate. Trust is
  decided afterwards by comparing the peer's public key with a stored pin.
* No ALPN is set. Cipher suites are the TLS 1.3 defaults of the platform.

Discovery on the LAN: DNS-SD service `_remotedesktop._tcp` on port 51515 with TXT keys `id` (device id, required),
`name` (display name), `v` (protocol version as decimal) (`ProtocolInfo.swift:39-47`). The type is shared with Apple's
Screen Sharing, so a browser MUST ignore entries without `id`. The advertisement is a hint only; nothing security
relevant is decided from it.

### 2.1 Connections

* LAN: two TCP connections to the host. The first frame on each, after TLS, is `connectionRole` (kind 0x01) with a
  one byte payload: 1 control, 2 video (`Framing.swift:197-200`). The control connection then handshakes. The video
  connection has no handshake; the host MUST refuse it unless an authenticated control session exists for the same
  client public key (`HostSession+Handshake.swift:51-61`, AGENTS.md "video-only is expected to be refused").
* Relayed: one connection only. After the relay splice, the client sends `connectionRole` 1 and handshakes as usual.
  There is no second TCP connection; video travels on the UDP lane with the control stream as fallback
  (`ClientSession.swift:429-430`, [video.md](protocol/video.md)).

## 3. Framing

```
u32 length (big endian)   counts the kind byte plus the payload; MUST be >= 1 and <= 16 MiB
u8  kind
payload (length - 1 bytes)
```

(`Framing.swift:109-193`.) A decoder MUST check the length before buffering, MUST accept frames split across reads
or coalesced in one read, and MUST fail on an unknown kind (`Framing.swift:155-157`).

| Kind | Name | Direction | Payload |
|---|---|---|---|
| 0x01 | connectionRole | C to H | 1 byte, 1 control or 2 video |
| 0x02 | clientHello | C to H | JSON `ClientHello` |
| 0x03 | serverHello | H to C | JSON `ServerHello` |
| 0x04 | pairConfirm | C to H | JSON `PairConfirm` |
| 0x05 | pairResult | H to C | JSON `PairResult` |
| 0x06 | command | C to H | JSON `RemoteCommand` |
| 0x07 | catalog | H to C | JSON `CaptureCatalog` |
| 0x08 | setCaptureSource | none | declared in the enum but never routed by the host; use the `setCaptureSource` command |
| 0x09 | videoConfig | H to C | JSON `VideoStreamConfig` |
| 0x0A | videoFrame | H to C | binary, see video.md |
| 0x0B | ping | C to H | JSON `PingPayload` (may be empty from old clients) |
| 0x0C | pong | H to C | echoes the ping payload |
| 0x0D | error | H to C | JSON `ErrorPayload` |
| 0x0E | pairCommit | both | JSON `PairingCommit` |
| 0x0F | pairReveal | both | JSON `PairingReveal` |
| 0x10 | notice | H to C | JSON `NoticePayload` |
| 0x11 | clipboardContent | H to C | JSON `ClipboardPayload` |
| 0x13 | audioConfig | H to C | JSON `AudioStreamConfig` |
| 0x14 | audioFrame | H to C | binary, see video.md |
| 0x15 | terminalRequest | C to H | JSON `TerminalRequest` |
| 0x16 | terminalEvent | H to C | JSON `TerminalEvent` |
| 0x17 | videoChunk | both lanes | binary chunk, see video.md |
| 0x18 | videoTransport | C to H | JSON `VideoTransportRequest` |
| 0x19 | videoKeyRequest | C to H | empty |
| 0x1A | videoKey | H to C | JSON `VideoKeyGrant` |
| 0x1B | directProbe | both, UDP only | empty, sealed |
| 0x1C | textFocus | H to C | JSON, only to a client that declared `supportsTextFocus` |
| 0x1D | fieldState | H to C | JSON, only to a client that declared `supportsFieldState` |
| 0x1E | agentRequest | C to H | JSON `AgentRequest` |
| 0x1F | agentEvent | H to C | JSON `AgentEvent` |
| 0x20 | previewRequest | C to H | JSON `PreviewProxyCommand` |
| 0x21 | previewEvent | H to C | JSON `PreviewProxyEvent` |
| 0x22 | pointerReport | H to C | JSON `NormalizedPoint`, only to a client that declared `supportsPointerReport` |
| 0x23 | clientState | C to H | JSON `{"background": bool}`, only to a host that declared `supportsClientState` |
| 0x24 | activityToken | C to H | JSON `ActivityTokenPayload`, only to a host that declared `supportsLiveActivityPush` |

(0x12 is unused.) A host that does not implement a kind it was never sent need not decode it. A host that receives
a kind it does not implement MUST ignore it rather than close, unless it is malformed.

## 4. Identity and pinning

* Each device has one long-term P-256 key. The host and the client use separate keys (Apple tags
  `pl.dmq.peering.host.identity` and `pl.dmq.peering.client.identity`, `SelfSignedIdentity.swift:19-20`).
* Each launch the device mints a fresh self-signed certificate over that key: version 3, ECDSA with SHA-256,
  subject and issuer `CN=<device name>, O=Peering`, `notBefore = now - 1 h`, `notAfter = now + 3650 days`,
  extensions BasicConstraints (critical, not a CA), KeyUsage digitalSignature, ExtendedKeyUsage serverAuth (host) or
  clientAuth (client) (`SelfSignedIdentity.swift:215-241`). Peers pin the key, not the certificate.
* The pin value is the 65 byte uncompressed point `0x04 || X || Y` (`SelfSignedIdentity.swift:37`). The Swift names
  it SPKI but it is not the DER SubjectPublicKeyInfo. UNVERIFIED: the host side obtains the same 65 bytes from
  `subjectPublicKeyInfoBytes` (`SelfSignedIdentity.swift:150`); implementers MUST compare against the point extracted
  from the certificate they actually received.
* The client takes the host key from the TLS certificate it received and never from a message. The host takes the
  client key from the client certificate. Comparisons MUST be constant time.
* A pin store maps a peer device id to its 65 byte key. The device id is a UUID string (uppercase, hyphenated).
* First pairing: the client TLS verifier accepts any server certificate and records the key; nothing is trusted until
  pairing succeeds (`TLSConfig.swift:87-91`). Afterwards a pinned host whose key differs MUST fail the connection.

## 5. Handshake

On the control connection, after `connectionRole`:

1. C sends `clientHello`.
2. H validates: version equal (else closes), `clientID` and `clientName` at most 256 UTF-8 bytes, client key present.
   If the id is pinned to a different key, H closes (`clientKeyMismatch`).
3. H sends `serverHello` with `alreadyPaired = (clientKeyIsPinned && lostPairing != true)`
   (`ClientHello.hostTreatsAsPaired`, `Handshake.swift:37`). `macAddresses` is included only when `alreadyPaired`.
   If `alreadyPaired` and `resumeSource` is present, H switches to that source.
4. C validates: version equal; if it dialled a specific host id, `serverID` MUST equal it; if it holds a pin for
   `serverID` the key MUST match; if it holds no pin and `alreadyPaired` is true it MUST refuse (the host's claim
   proves nothing) (`ClientSession+Handshake.swift:29-76`).
5. If `alreadyPaired`: both sides are ready. Otherwise section 6.

Ready state: C pings every 1 s (`ClientSession+Liveness.swift:9`) and H answers with `pong` echoing the payload.
H pushes `catalog` unsolicited shortly after ready; it can arrive after the first pong. C sends its quality tier
(`setStreamQuality`) as soon as it is ready. H checks every 5 s and ends an authorised session silent for more than 60 s, an unauthenticated one silent for
more than 30 s, and a pairing awaiting approval silent for more than 120 s (`HostServer.swift:310-319`). Any frame
counts as liveness.

## 6. Pairing (short authentication string)

Both screens show six digits derived from the handshake; the user confirms they match. Domain strings and layout:

```
commitment(eph, nonce) = SHA256("MacCast-Pairing-commit-v1" || eph || nonce)      eph = 65 byte P-256 x9.63 point, nonce = 32 random bytes
```

Order (each side commits before it sees the other's reveal, `PairingSAS.swift:9-18`):

1. C to H `pairCommit{commitment}`
2. H to C `pairCommit{commitment}`
3. C to H `pairReveal{ephemeralPublicKey, nonce}`
4. H to C `pairReveal{ephemeralPublicKey, nonce}`

Each side verifies the other's reveal against its commitment (constant time) and then builds the transcript
(`PairingSAS.swift:112-134`): the concatenation of the following fields, each as `u32 big-endian length || bytes`:

1. UTF-8 `"MacCast-Pairing-SAS-v1"`
2. protocolVersion as `u16` big endian (2 bytes)
3. clientID UTF-8
4. serverID UTF-8
5. client ephemeral public key
6. server ephemeral public key
7. client nonce
8. server nonce
9. server identity public key (the 65 byte point from the TLS certificate)

Code = first four bytes of `SHA256(transcript)` as a big-endian `u32`, modulo 1,000,000, formatted as six digits with
leading zeros (`PairingSAS.swift:65-78`). Frozen check: protocol version 1, client id `iphone-15-pro-max`, server id
`mac-studio-01`, client ephemeral 65 x 0xA1, server ephemeral 65 x 0xB2, client nonce 32 x 0xC3, server nonce 32 x 0xD4,
server identity 65 x 0xE5 yields `365357` (`PairingSASTests.swift:56`). No key agreement is performed; the ephemeral
keys only feed the transcript, so a new P-256 key per pairing is the safe way to produce them.

5. H displays the code and a QR code, then waits.
6. C shows the code, the user confirms, C sends `pairConfirm{accepted, proof?}`. If the user rejects, `accepted=false`.
7. If `proof` is present, H verifies `proof == HMAC-SHA256(key = secret, message = "MacCast-Pairing-proof-v1" || transcript)`
   with `secret` the 16 random bytes it put in the QR (`PairingSAS.swift:51-63`, `HostSession+Handshake.swift:233,258`). A
   valid proof means the client saw the host screen, so H pairs without asking. No proof: H asks its own user to approve.
8. H pins the client key, then sends `pairResult{accepted, reason?}`. C pins the host key only after `accepted`. A side
   whose store write fails MUST report failure, not success.

Pairing QR payloads (`PairingPayload.swift`):

* Host identity link: `https://getpeering.app/mac?id=<UUID uppercase>` (the scanner also accepts a bare UUID).
* Code link: `peering://pair?code=NNNNNN&secret=<lowercase hex>`; six digits alone are also accepted when typed.
  The two parsers refuse each other's payload.

## 7. JSON encoding rules

Control payloads are the output of Swift's `JSONEncoder` with default settings (relay signalling is the exception,
see relay.md). Reproduce these rules exactly:

* Struct: object with property names as keys. An optional that is nil is an absent key, never `null`. Decoders MUST
  accept both absent and `null`.
* Enum without associated values and a string raw value: the raw string (`"h264"`, `"left"`).
* Enum with an integer raw value: the integer (`MouseButton`: left 0, right 1, middle 2).
* Enum with associated values: an object with one key, the case name, whose value is an object of the labelled values
  (`{"mouseMove":{"to":{"x":0.5,"y":0.25}}}`). An unlabelled value is keyed `_0`
  (`{"setVideoEnabled":{"_0":false}}`, confirmed by `ProtocolModelTests.swift:341`). A case with no values is an
  empty object (`{"lockScreen":{}}`, UNVERIFIED).
* `Data`: standard base64 with padding. `UUID`: uppercase hyphenated string. `Date`: a number of seconds since
  2001-01-01T00:00:00Z (no date strategy is configured anywhere in the repository).
* `Double`/`Int`: JSON numbers. `UInt16`/`UInt32`/`UInt64` values are plain integers.
* `CGSize`: an array `[width, height]` (UNVERIFIED).
* Dictionaries with string keys are objects.
* `Modifiers` is a bare integer (`RemoteCommand.swift:21-31`).

Hello flags are the whole capability mechanism. A flag absent or false means unsupported.

`ClientHello`: `clientID`, `clientName`, `protocolVersion`, `wantsPairing`, and optional `supportsClipboardImages`,
`supportsTextFocus`, `supportsFieldState`, `supportsPointerReport`, `supportsAgentChat`, `supportsAgentPermissionModes`,
`supportsAgentUsage`, `resumeSource` (a `CaptureSource`), `lostPairing`.

`ServerHello`: `serverID`, `hostName`, `protocolVersion`, `alreadyPaired`, and optional `macAddresses` (array of strings),
`supportsVideoPause`, `supportsClipboardImages`, `supportsMosaic`, `supportsSourceThumbnails`, `supportsDeviceOrientation`,
`supportsVirtualDisplayManagement`, `pushesTerminalAlertsWhileConnected`, `supportsAgentList`, `supportsAgentChat`,
`supportsFileBrowser`, `supportsAgentModelPicker`, `agentChatAgents` (array of strings), `supportsAgentPermissionModes`,
`supportsAgentUsage`, `supportsAgentSessionImport`, `supportsAgentPause`, `supportsClientState`, `supportsLiveActivityPush`.

Additive fields, read by the Mac host from the build after the shipped one (older builds ignore them): `ClientHello.clientPlatform`,
`ClientHello.videoCodecs` (ordered array of `"h264"`/`"hevc"`, best first), `ServerHello.hostPlatform` (`"macos"` from the Mac host).
`ClientHello.sessionRef` (optional string, 8 lowercase hex characters, random per connection attempt and kept across automatic resumes) is an analytics tag only: the Mac copies it onto its own events when it is well formed and otherwise drops it. Android and Windows clients do not send it.
A client that omits `videoCodecs` is assumed to decode both. A client that lists codecs without the host's choice (HEVC by default)
gets H.264 for the stream it is served; the host restarts capture when the served client needs another codec.

## 8. Commands (`command`, kind 0x06)

JSON of `RemoteCommand` (`RemoteCommand.swift:75-132`). A command is never sent unless its guard holds.

| Case | JSON | Guard |
|---|---|---|
| mouseMove | `{"mouseMove":{"to":{"x":0.5,"y":0.5}}}` | none; coordinates normalized 0..1 of the captured source |
| mouseDown / mouseUp | `{"mouseDown":{"button":0}}` | none; never dropped or reordered |
| scroll | `{"scroll":{"dx":0,"dy":-12.5}}` | none; accumulates when coalesced |
| keyDown / keyUp | `{"keyDown":{"keyCode":36,"modifiers":0}}` | none; macOS virtual keycode |
| textInput | `{"textInput":{"_0":"hello"}}` | none |
| switchSpace | `{"switchSpace":{"direction":"left"}}` | host support |
| switchToSpace | `{"switchToSpace":{"display":1,"index":2}}` | catalog `spaceInfo` present |
| joystickMove | `{"joystickMove":{"dx":0,"dy":0}}` | none |
| setCaptureSource | `{"setCaptureSource":{"_0":{"display":{"_0":1}}}}` | none for display/window/application; mosaic needs `supportsMosaic` |
| launchApplication | `{"launchApplication":{"bundleIdentifier":"x"}}` | host support |
| setStreamQuality | `{"setStreamQuality":{"fps":0,"bitrateKbps":8000}}` | none; 0 means keep; host clamps to 100000 kbps and `fps` to 15..120 (a frame rate cap on what is sent; 120 lifts it) |
| setVideoEnabled | `{"setVideoEnabled":{"_0":false}}` | `supportsVideoPause` |
| refreshSpacePreviews, refreshSourceThumbnails | `{"refreshSourceThumbnails":{}}` | `supportsSourceThumbnails` for the latter |
| watchSourceThumbnails | `{"watchSourceThumbnails":{"_0":true}}` | `supportsSourceThumbnails` |
| setPrivacyMode | `{"setPrivacyMode":{"enabled":true}}` | host support |
| lockScreen | `{"lockScreen":{}}` | `hostPlatform` in the ServerHello: a Mac (`"macos"`, or absent from a host that predates the field) can lock, a Windows host cannot; no `supportsLockScreen` flag exists |
| requestClipboard | `{"requestClipboard":{}}` | none |
| pushClipboard | `{"pushClipboard":{"text":"x"}}` | none |
| pushClipboardImage | `{"pushClipboardImage":{"png":"<base64>"}}` | `supportsClipboardImages` |
| reportDeviceOrientation | `{"reportDeviceOrientation":{"isLandscape":true}}` | `supportsDeviceOrientation` |
| addVirtualDisplay | `{"addVirtualDisplay":{"name":"","width":1170,"height":2532,"startLandscape":false}}` | `supportsVirtualDisplayManagement` |
| removeVirtualDisplay, renameVirtualDisplay | `{"removeVirtualDisplay":{"displayID":5}}` | same |
| performWindowAction | `{"performWindowAction":{"windowID":7,"action":"close"}}` | host support |
| openNewWindow | `{"openNewWindow":{"bundleIdentifier":"x"}}` | host support |

Delivery semantics: `mouseMove` and `reportDeviceOrientation` keep only the latest; `scroll` and `joystickMove` sum;
everything else is delivered in order and never coalesced. Mouse moves are limited to about 60 Hz.
Input commands (`isUserInput`) are ignored by a host in observe mode while stream and session controls still work.

`CaptureSource` JSON: `{"display":{"_0":<u32>}}`, `{"application":{"_0":<i32 pid>}}`, `{"window":{"_0":<u32>}}`,
`{"mosaic":{"_0":{...}}}` (`CaptureSource.swift:6-15`). `stableID` strings are `display:<n>`, `application:<n>`, `window:<n>`.

`CaptureCatalog` (`CaptureSource.swift:483`): `displays`, `applications`, `windows`, `installedApplications`, `spaceInfo?`;
each list may be absent. A descriptor has `id`, `kind`, `title`, `subtitle?`, `bundleIdentifier?`, `iconPNGData?` (at most 48 KiB),
`thumbnail?`, `source`, `pixelSize` (real pixels, not points), `isManagedVirtualDisplay`, `isVirtualDisplay`.

Key semantics: `keyCode` values are macOS virtual keycodes and `modifiers` are bits 17 shift, 18 control, 19 option, 20 command;
bit 8 asks for the F-key's printed action (`Modifiers.topRowAction`). See [keymap.md](protocol/keymap.md).

## 9. Other control messages

* `error` (0x0D): `{code, message}`. The code `hostStopped` means the user pressed Stop; the client MUST NOT reconnect.
* `notice` (0x10): `{message?, symbol?, lockedDisplayID?}`; a nil message clears a standing condition.
* `videoTransport` (0x18): `{transport:"primary"|"control", reason}`. The host may decline.
* `clientState` (0x23): `{"background": true}` or `{"background": false}`, control lane, never answered. An OS may freeze a
  backgrounded client with its sockets open and tell the host nothing, so a client that leaves the foreground says so
  first. A client MUST send it only to a host whose `ServerHello` carried `supportsClientState: true`, and only on a
  change. On `true` the host stops sending video to that session exactly as for `setVideoEnabled(false)` and allows the
  session 180 s of silence instead of 60 s. On `false` it restores the 60 s limit, resumes video (with a keyframe) unless
  the client had paused the picture itself, and a client that never returns is still reaped at 180 s. A client that keeps
  drawing in the background (picture in picture) sends `false` while it does. No protocol version change.
* `activityToken` (0x24): `{"activity":"session"|"agentChat","pushToken":"<hex>"|null,"pushToStartToken":"<hex>"|null,
  "environment":"production"|"sandbox"}`, control lane, never answered. The keys are always present, null included. It
  hands the host the iOS Live Activity push tokens so the host can keep a card moving through the relay
  (`notifyActivity`, see relay.md) while iOS has the app frozen. A client MUST send it only to a host whose `ServerHello`
  carried `supportsLiveActivityPush: true`, only once the session is ready, whenever a token appears or changes, and
  again after each reconnect. Both tokens null means the activity ended; a client that still holds a push-to-start
  token keeps sending it with `pushToken` null, so the host can raise a new card. The host pushes only coded state (ids,
  states, counts, times, a short `hostKey` derived from the Mac id), never a Mac name, chat title or reply, and only while
  the phone is not in the foreground. No protocol version change.
* Terminal, file and agent requests and events are JSON enums in `TerminalWire.swift` and `AgentWire.swift`
  (documented by the vectors; a prose reference for each is a follow-up). File paths are POSIX shaped and the permissions
  string is a 10 character `ls -l` style mode. A non-POSIX host presents a virtual tree (`/C:/Users/me`).
* Windows terminals: a session belongs to the client id that created it and survives that client's connection; `list`
  answers a snapshot followed by the retained output (at most 512 KiB, sent in events of at most 64 KiB). File requests
  are answered only for a running terminal of the client or a scope it opened with `startBrowser` (four per client).
  The host sets `supportsAgentList` and does not set `pushesTerminalAlertsWhileConnected`: it pushes an alert only
  while the client is not connected.
* Push registration: `terminalRequest` `registerPushToken` carries opaque bytes. The host hex-encodes them verbatim
  and forwards them to the relay for `notifyDevice`. Android registers the UTF-8 bytes `fcm:` followed by the FCM token.
