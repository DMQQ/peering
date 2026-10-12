# Connection analytics events (iPhone app)

Sent to PostHog by `apple/MacCast/App/Analytics.swift` and `Analytics+Connection.swift`, off with the one switch in Settings. Every value is a member of a closed set, a bucket, a boolean or a number. Never sent: a Mac's name, a device name, an address, a port, an id, a file name, an error sentence or anything typed. The closed sets are built in `MacCastKit` (`ConnectionTelemetry`, `ConnectionBuckets`, `RouteAttemptLog`, `SessionEndReason`, `NetworkContext`) and in `RemoteCore` (`ConnectStage`, `TransportErrorDetail`, `FailureDiagnosis`), each with tests.

## On every event

| Property | Values |
| --- | --- |
| `$process_person_profile` | `false` (a user is a device) |
| `app_version`, `app_build` | the bundle's version strings |
| `os_major` | iOS major version |
| `internal_build` | `true` for Debug and TestFlight builds (receipt named `sandboxReceipt`), else `false`. Filter on `internal_build = false` to leave the owner's devices out. |

## Shared connection properties

Carried by `session_started`, `connect_failed` and `session_ended` unless noted.

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
`route`: `discovered`, `relay`, `pairing`, `address`.

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

## The retry cap

After three consecutive sessions that ended in `unresponsive` or `transport` with no stable stretch between (a stretch is stable if it ran two minutes, or kept a picture arriving for one minute), automatic retries stop and the failed-session screen shows "Connection keeps dropping. Check that the computer is awake and on a good network, then try again." A manual connect or a stable session resets the count. The stop is reported as `session_ended` with `end_reason = retryCapped`. A relay refusal during an automatic retry shows the allowance sheet and never the paywall.
