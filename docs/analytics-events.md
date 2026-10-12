# Analytics events (iPhone app and Mac host)

Android and Windows send no analytics. Everything below is from the iPhone app or the Mac host.

Sent to PostHog by `apple/MacCast/App/Analytics.swift` and `Analytics+Connection.swift`, off with the one switch in Settings. Every value is a member of a closed set, a bucket, a boolean or a number. Never sent: a Mac's name, a device name, an address, a port, an id, a file name, an error sentence or anything typed. The closed sets are built in `MacCastKit` (`ConnectionTelemetry`, `ConnectionBuckets`, `RouteAttemptLog`, `SessionEndReason`, `NetworkContext`) and in `RemoteCore` (`ConnectStage`, `TransportErrorDetail`, `FailureDiagnosis`), each with tests.

## On every event

| Property | Values |
| --- | --- |
| `$process_person_profile` | `false` (a user is a device) |
| `app_version`, `app_build` | the bundle's version strings |
| `os_major` | iOS major version |
| `internal_build` | `true` for Debug and TestFlight builds (receipt named `sandboxReceipt`), else `false`. Filter on `internal_build = false` to leave the owner's devices out. |

## Joining the two ends

`session_ref` is 8 random hex characters made on the phone for each connection attempt and kept across automatic resumes of the same session. The phone puts it on `connect_started`, `session_started`, `connect_failed`, `session_ended` and `pairing_failed`, and sends it in the hello as the optional `sessionRef`. The Mac copies it (only if it is exactly 8 lowercase hex characters) onto `host_session_started`, `host_session_ended` and `host_error`. A phone from before the field, or an Android client, leaves it out and the Mac events simply lack it.

## Shared connection properties

Carried by `session_started`, `connect_failed` and `session_ended` unless noted, plus `session_ref`.

| Property | Values |
| --- | --- |
| `route_attempts` | ordered routes tried with their outcome, e.g. `lan:timedOut,relay:ok`. Route is `lan`, `relay` or `address`. Outcome is `ok`, `pending` (not settled yet) or a `reason` value. Newest six kept. |
| `network_interface` | `wifi`, `cellular`, `wired`, `other`, `none` |
| `is_expensive`, `is_constrained` | boolean, from the network path |
| `network_path_changes` | number of path changes since the session first became ready |
| `host_platform` | `mac`, `windows`, `unknown` (from the hello's `hostPlatform`; absent in older hosts) |
| `quota_remaining_bucket` | relay sessions only: `unlimited`, `0`, `<5m`, `<15m`, `>=15m` |

The hello carries no host app version or host OS version, so neither is reported. Adding them needs an optional hello field on the hosts.

## Events

### `connect_started`
`route`: `discovered`, `relay`, `pairing`, `address`. Plus `session_ref`.

### `session_started`
Fires the first time a session becomes ready. `path` (`LAN`, `RELAY`, `DIRECT`), `plan` (`free`, `relay`, `pro`, `unknown`), `ms_to_ready` (number, dial to ready), plus the shared properties.

### `connect_failed`
A dial failed or a session dropped.

| Property | Values |
| --- | --- |
| `reason` | `busy`, `protocolMismatch`, `pinMismatch`, `noPinOnFile`, `hostIDMismatch`, `identity`, `handshake`, `pairingRefused`, `pairingNotSaved`, `pinsUnreadable`, `timedOut`, `hostClosed`, `refused`, `transport`, `relay`, `hostReportedError`, `unresponsive`, `unresponsiveAfterCheck`, `videoLost`, `other`, `unknown` |
| `stage` | `resolving`, `connecting`, `tls`, `handshake`, `pairing`, `ready`, `streaming`, `video`. How far the session got. A TLS error while connecting reads `tls`; a lost picture reads `video`. |
| `error_domain`, `error_code` | only for a Network.framework error: domain `posix` (errno), `dns` (DNSServiceErrorType) or `tls` (OSStatus, where a TLS alert lands); code is the number. |
| `ms_to_ready` | number, when the session had been ready |
| `last_frame_age_ms` | number, since the last picture; absent if none ever arrived |
| `last_pong_age_ms` | number, since the Mac last answered a ping; absent if never |
| `rtt_ms` | number, last measured median round trip |
| `after_ready` | `true`, `false` |
| `path` | `LAN`, `RELAY`, `DIRECT` |
| `reconnect_attempt` | number |
| `seconds_into_session` | number, absent if not in a session |
| `app_state` | `active`, `inactive`, `background`, `unknown` |
| `pip_active` | `true`, `false` |
| `consecutive_drops` | number, the run of `unresponsive`/`transport` drops without a stable stretch (see retry cap) |
| `video_recorded`, `video_transport`, `fell_back`, `first_picture_ms` | `video_transport` is `primary` or `control`; `first_picture_ms` absent if no picture arrived |

Plus the shared properties.

### `session_ended`
Once per session that reached ready, when it ends for good: the user ends it, the Mac stops, the reconnect ladder gives up, iOS ends it, the relay allowance runs out or the retry cap stops it.

| Property | Values |
| --- | --- |
| `end_reason` | `user`, `hostClosed`, `unresponsive`, `transport`, `backgrounded`, `quota`, `error`, `retryCapped` |
| `duration_s` | number, connected seconds summed over the session's stretches |
| `reconnects` | number of automatic reconnects that came back |
| `video_bytes_bucket` | `0`, `<1MB`, `<10MB`, `<100MB`, `<1GB`, `>=1GB` |
| `dropped_frames_bucket` | `0`, `<10`, `<100`, `<1000`, `>=1000` |
| `path`, `video_*`, `fell_back`, `first_picture_ms` | as above |

Plus the shared properties.

### `relay_allowance_exhausted`
`path`: `LAN`, `RELAY`, `DIRECT` or `unknown`.

### `pairing_accepted`, `pairing_declined`
No properties.

## Mac host events

All carry `app_version`, `app_build`, `os_major` (the Mac's macOS major version) and `$process_person_profile = false`.

### `host_session_started`
`route` (`lan`, `relay`), `client_platform` (`ios`, `android`, `unknown`), `session_ref` when the phone sent one.

### `host_session_ended`
| Property | Values |
| --- | --- |
| `end_reason` | `clientClosed`, `silence`, `backgroundedSilence`, `forgotten`, `hostStopped`, `error`, `replaced` |
| `duration_s` | number |
| `route` | `lan`, `relay`, `direct` |
| `client_platform` | `ios`, `android`, `unknown` |
| `bytes_sent_bucket` | `0`, `<1MB`, `<10MB`, `<100MB`, `<1GB`, `>=1GB` |
| `dropped_frames_bucket` | `0`, `<10`, `<100`, `<1000`, `>=1000` |
| `encoder_restarts` | number, capped at 20 |
| `session_ref` | when the phone sent one |

`silence` is the reaper ending a session whose phone stopped answering; `backgroundedSilence` is the same after the phone said it left the foreground. `forgotten` is the Mac unpairing the phone. `replaced` is the same phone opening a second session. When no reason was noted the phone closed it (`clientClosed`).

### `host_error`
| Property | Values |
| --- | --- |
| `code` | `captureFailed`, `captureStopped`, `permissionRevoked`, `encoderFailed`, `relayDisconnected`, `relayRegistrationFailed`, `virtualDisplayFailed`, `agentCrashed`, `fileTransferFailed`, `pairingRefused`, `hookInstallFailed` |
| `stage` | where it happened, where that is meaningful: `capture`, `stream`, `encode`, `start`, `register`, `connection`, `confirm`, `proof`, `approval`, `save`, or an area name (`display`, `agent`, `fileTransfer`, `permission`) |
| `error_code` | number: OSStatus, errno, SCStreamError or NWError code |
| `recovered` | boolean, only where the site knows: `true` on the error a capture rebuild answered, sent once the rebuild worked; `false` on `captureFailed` at stage `recovery` when the host gave up |
| `count` | number of occurrences this event stands for. At most one event per `code` per minute is sent; the rest are counted into the next. |
| `session_ref` | the most recent open session's tag, when there is one |

## Phone failure events

Each has `reason` from a closed set, usually `stage`, and `error_code` (a POSIX, URL or Cocoa error number) when there is one. `cause` values used as `reason`: `cancelled`, `timedOut`, `offline`, `dnsFailed`, `refused`, `unreachable`, `hostClosed`, `tls`, `denied`, `notFound`, `diskFull`, `unreadable`, `hostReported`, `other`.

| Event | `stage` | `reason` | Also |
| --- | --- | --- | --- |
| `pairing_failed` | `codeEntry`, `qr`, `commit`, `confirm`, `pinStore` | the `connect_failed` reasons at the pairing stage, plus `codeMismatch`, `cancelled`, and for typed input `empty`, `pairingCodeNotAnID`, `notAPairingCode`, `notAnID` | `session_ref` |
| `file_transfer_failed` | `measure`, `read`, `send`, `write` | a cause | `direction` (`up`, `down`), `size_bucket` (byte buckets or `unknown`) |
| `terminal_failed` | `start`, `stream` | `hostReported` | |
| `ssh_failed` | `dns`, `connect`, `handshake`, `hostKey`, `auth`, `channel`, `sftp` | a cause, or `rejected`, `changed`, `forwardFailed` | |
| `agent_failed` | `start`, `stream`, `approval`, `commit`, `push` | `hostReported`; for `approval`, `offline` (no usable connection) or `timedOut` (the Mac did not confirm) | |
| `push_registration_failed` | none | `noEntitlement`, `simulator`, or a cause | |
| `purchase_failed` | none | a StoreKit case name (`networkError`, `systemError`, `notAvailableInStorefront`, `productUnavailable`, `purchaseNotAllowed`, ...) or a cause | `product`: `pro_lifetime`, `pro_yearly`, `pro_monthly`, `other` |
| `receipt_verification_failed` | none | `invalidSignature`, `invalidCertificateChain`, `revokedCertificate`, `invalidDeviceVerification`, `invalidEncoding`, `missingRequiredProperties`, `other` | `product` as above |
| `pin_store_unreadable` | none | `keychain` (with the OSStatus as `error_code`) or `undecodable` (`error_code` -1) | once per launch |

`terminal_failed` and `agent_failed` carry no detail because the Mac's own sentence is free text. A relay allowance refusal is not a separate event: it is `relay_allowance_exhausted`. `agent_failed` at `approval` is an answer from a notification button that the Mac did not confirm; at `commit` and `push` it is a git result that reported failure.

## How to investigate a failure

Find one session on both sides, from a `session_ref` in a phone event:

```sql
SELECT timestamp, event, properties.end_reason, properties.reason, properties.stage, properties.code
FROM events
WHERE properties.session_ref = '0a1b2c3d'
ORDER BY timestamp
```

Failures by stage and reason over the last week, leaving the owner's devices out:

```sql
SELECT properties.stage AS stage, properties.reason AS reason, count() AS failures
FROM events
WHERE event = 'connect_failed' AND properties.internal_build = false AND timestamp > now() - INTERVAL 7 DAY
GROUP BY stage, reason
ORDER BY failures DESC
```

Drops and what the Mac saw: phone `connect_failed` joined to the Mac's `host_session_ended` on `session_ref`.

```sql
SELECT p.properties.reason AS phone_reason, p.properties.stage AS phone_stage, h.properties.end_reason AS host_end_reason, count() AS drops
FROM events p
JOIN events h ON h.properties.session_ref = p.properties.session_ref AND h.event = 'host_session_ended'
WHERE p.event = 'connect_failed' AND p.properties.after_ready = 'true' AND p.timestamp > now() - INTERVAL 7 DAY
GROUP BY phone_reason, phone_stage, host_end_reason
ORDER BY drops DESC
```

## The retry cap

After three consecutive sessions that ended in `unresponsive` or `transport` with no stable stretch between (a stretch is stable if it ran two minutes, or kept a picture arriving for one minute), automatic retries stop and the failed-session screen shows "Connection keeps dropping. Check that the computer is awake and on a good network, then try again." A manual connect or a stable session resets the count. The stop is reported as `session_ended` with `end_reason = retryCapped`. A relay refusal during an automatic retry shows the allowance sheet and never the paywall.
