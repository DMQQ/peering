# Relay signalling

Part of the [protocol](../protocol.md). Sources: `relay/src/protocol.rs`, `relay/src/signalling.rs`,
`relay/src/tcp_relay.rs`, `relay/src/udp_relay.rs`, `RelayProtocol.swift`, `RelayDeviceProof.swift`,
`RelayHostRegistration.swift`.

The relay introduces two devices and copies bytes it cannot read. It never terminates the end to end TLS session and never
learns the video key. Its tokens are routing hints, not credentials.

## 1. Signalling socket

WebSocket to `wss://getpeering.app/` (`ProtocolInfo.swift:35`). Text frames, one JSON object each, at most 64 KiB. The
relay drops a socket silent for 90 s (`PEERINGD_IDLE_SECONDS`), so a long lived socket pings. Unparseable input is answered
`{"type":"error","code":"protocol",...}`. Encoding is not Swift-enum style: every message is an object tagged by `type`, keys
are camelCase, byte values are lowercase hex, encoders sort keys (`RelayMessageCodec`, `RelayProtocol.swift:306`), and
optional fields are absent when unset. The relay reads `plan`, `jwsRepresentation`, `publicKey` and `proof` leniently: a value
that is not a string counts as absent.

### Client to relay

| type | fields |
|---|---|
| `registerHost` | `deviceId`, `name`, `protocolVersion` (must be 20), optional `publicKey`, `proof`, `proofTime` |
| `connectToHost` | `hostId`, `clientId`, `protocolVersion`, optional `apiKey`, `plan`, `jwsRepresentation`, `publicKey`, `proof`, `proofTime` |
| `requestPeerAddress` | `videoToken` (own token, 32 hex) |
| `hostPresence` | `hostId` |
| `ping` | none |
| `referralStatus` | `clientId`, `publicKey`, `proof`, `proofTime` |
| `redeemReferral` | `clientId`, `code`, `publicKey`, `proof`, `proofTime` |
| `notifyDevice` | registered hosts only: `deviceToken` (hex), `title`, `body`, optional `source`, `category`, `sessionId`, `approvalId` |

Limits (`signalling.rs`): `deviceId`, `name`, `hostId`, `clientId`, `apiKey` at most 256 bytes; `deviceToken` at most 128
characters today (raised for FCM by REL-001), `title` 256, `body` 512, `source`/`category`/`sessionId` 128, `approvalId` 256.

Proofs. `publicKey` is the hex of the 65 byte point, `proof` is the hex of a DER encoded ECDSA P-256 / SHA-256 signature, and
`proofTime` is Unix seconds, accepted within 300 s of the relay clock (`device_proof.rs:40,99`). Signed messages (UTF-8, newline
separated, no trailing newline; `RelayDeviceProof.swift:17-49`):

* host registration: `peeringd-host-registration-v1\n<deviceId>\n<proofTime>`
* client: `peeringd-client-registration-v1\n<clientId>\n<proofTime>`
* referral status: `peeringd-referral-v1\nstatus\n<clientId>\n<proofTime>`
* referral redeem: `peeringd-referral-v1\nredeem:<code>\n<clientId>\n<proofTime>`

The client proof keys the free allowance to the device key instead of the resettable id. Proofs are optional on the wire and
a missing proof is not a refusal, but a proven host id can only be claimed by the key that proved it (`deviceRefused`).

### Relay to client

| type | fields |
|---|---|
| `registered` | `sessionTtlSeconds` |
| `sessionReady` | `controlHost`, `controlPort`, `videoHost`, `videoPort`, `controlToken`, `videoToken` (tokens: 32 hex digits = 16 bytes), `remainingSeconds?` (unsigned integer: seconds of relay time the client's metered plan has left in the current one-day window, referral bonus included; omitted when the plan is unmetered, so absence means unlimited) |
| `hostOffline` | `deviceId` |
| `peerAddress` | `host`, `port` |
| `hostPresence` | `hostId`, `online` (registration with the relay, not reachability) |
| `referral` | `code`, `bonusSeconds`, `bonusEndsAt?`, `redeemed`, `invitesEarned`, `invitesMax` |
| `pong` | none |
| `error` | `code`, `message` |

Error codes seen in the relay source: `protocol`, `invalid`, `deviceRefused`, `quotaExceeded`, `version` (host and client
protocol versions differ), `peerAddressUnknown` (normal first answer to `requestPeerAddress`), `unauthorized`, `tooManyRequests`
and the referral codes. An unknown `type` from the relay SHOULD be ignored, not fatal.

## 2. Host registration

1. Open the socket, send `registerHost` with a fresh proof (the time window makes an old proof useless), wait for `registered`.
2. Keep the socket open: it is the presence. Send `ping` every 25 s. On loss, reconnect with delays 1, 2, 5, 10, 30 s then
   30 s, re-signing each time.
3. A `sessionReady` pushed to the host means a client asked for it. Open TCP to `controlHost:controlPort`, write the 16 byte
   `controlToken`, then run the TLS server handshake on that same socket. Treat it exactly like an accepted LAN connection.
   Bind the video lane with `videoHost:videoPort` and `videoToken` when the client asks for a key.

## 3. Client session

1. Open the socket, send `connectToHost`, read until `sessionReady` or `hostOffline` or `error` (ignore `pong`).
2. Open TCP to `controlHost:controlPort`, write the 16 byte `controlToken`, then run the TLS client handshake on that socket
   and continue as in the main spec. The relay waits up to 5 s for the token, pairs the two sockets by token, and splices them.
3. The relay meters the splice against the client's plan; at the end of the allowance it closes the splice. Free: 30 minutes per
   rolling 24 hours per proven device key (`config.rs:184-219`). Paid plans are unmetered. A receipt that does not verify counts as
   free, never as a refusal.
4. `hostPresence` is asked only while the connect screen is open, never in the background.

## 4. Video datagrams

One UDP socket on `videoHost:videoPort` serves every session. Each datagram starts with the sender's 16 byte video token; the
relay looks it up, strips it, and forwards the rest to the other end's last seen address. A datagram of exactly 16 bytes is a
bind and is not forwarded. Everything after the token is ciphertext. See [video.md](video.md) for the sealing.

## 5. Push

`notifyDevice` is sent by a registered host with the token its client registered (`registerPushToken`). Today the relay sends
APNs only. With REL-005 a token whose decoded bytes begin with the ASCII `fcm:` goes to Firebase Cloud Messaging with the
remaining bytes as the FCM registration token.

## 6. Proposed additions (additive, not shipped)

`connectToHost.playPurchaseToken` and `playProductId` for Google Play purchases (REL-008). Old clients and old relays ignore
unknown keys, and the relay treats a missing or unverifiable purchase as the free plan.
