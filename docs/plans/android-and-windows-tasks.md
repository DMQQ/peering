# Android and Windows: task breakdown

Companion to [android-and-windows.md](android-and-windows.md) (the plan: protocol facts, decisions, risks).
This file is what agents build from. Status lives in each task line and is updated in the commit that finishes the task.

## Shared header (every agent reads this)

**Git hygiene.** Commit only files your task owns, by name. Never `git add -A` or `git add .`. Run `git status`
before each commit and never commit or revert files you did not write. Pull and rebase before any push (the owner
pushes). One commit per finished task, after its tests pass. Commit message: one imperative line saying what changed
and why it matters, then the line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Stay on the `monorepo`
branch. Work only in `android/`, `windows/`, `docs/`, `.github/workflows/` and, where a REL task says so, `relay/`.
Do not touch `apple/` without asking.

**Style (from CLAUDE.md).** Comment only what code cannot say: non-obvious logic, or a trap already hit. No history,
no design essays, no commented-out code. Files stay under about 300 lines, functions under about 40, one main type
per file. Names say what a thing is; Bools read as statements. No force unwrap or `unwrap()` on input that arrives off
the wire. No `try?`/ignored errors where the user would lose something. User visible text goes through string
resources (Android) or one `strings` module (Windows). No em dashes, en dashes or spaced hyphens anywhere.
Never put personal paths, emails or tokens in tracked files.

**Wire compatibility.** The shipped iOS app (protocol version 20) must keep working. Never change an existing field;
add optional fields or capability flags only; do not bump `ProtocolInfo.version`. Send a feature only after the peer
declared it. Unknown inbound JSON keys are ignored; unknown enum cases fail the message, so guard with flags.

**Testing policy.** Logic and flows are tested; UI rendering is not (no screenshot tests, no Compose UI tests, no tray
tests). Anything with parsing, state machines, reducers, queues, policy, crypto, protocol, pairing, reconnect or
fallback ships unit tests named for the behaviour, with no sleeps and nothing shared between tests.
Android: JUnit5 or JUnit4 with `kotlinx-coroutines-test` and Turbine, on pure Kotlin/JVM modules (`core:wire`,
`core:session`). Keep logic out of Android classes so `./gradlew :core:wire:test :core:session:test` runs on a laptop.
Windows: `cargo test` with core logic in `peering-wire` and `peering-core`, which have no Windows API dependency and
must pass on Linux (`cargo test -p peering-wire -p peering-core`). Flow tasks drive the logic layer (state holder or
service level) with fake transports and the shared vectors in `docs/protocol/vectors/`.

**Android design rule (owner decision 1).** Every Android UI task follows the visual language of `wiki/DESIGN.md` (a local, untracked file: read it, never copy it into the repo): dark only, no dynamic colour, near-black backdrop `#0A0A0B`, ink and surfaces as opacities of white, one state blue `#0A84FF` as the only accent, cards outlined and never filled, Material 3 components and behaviour underneath. Where Material 3 cannot do something natively, adapt and note it in the task commit. The theme lives in `feature/theme` (AND-060). Definition of done for a UI task also includes: uses only theme tokens, no hard coded colours, builds with `./gradlew :app:assembleDebug`.

**Decisions** are recorded in the plan, section 10 (pluggable billing, FCM from a gitignored config, unsigned Windows build, native-only agents, HEVC later).

**Task format.** `ID | Status | kind | size`, then Port (Apple sources to read), Owns (files only this task edits),
Deps, Done (checkable), Commit (the message line). Kinds: foundation, parallel-safe, integration. All sizes are S
(one short session) unless stated. Status values: todo, done, blocked, later (LATER or SKIP, not scheduled).

**Needs the user** is the last section.

## Wave table

| Wave | Tasks that can run at the same time |
|---|---|
| 0 | SPEC-001..004, SPEC-005..009, AND-001, WIN-001, CI-001, CI-002, REL-001, REL-002 |
| 1 | AND-002, WIN-002, then all pure logic: AND-010..036, WIN-010..030, REL-003..005 |
| 2 | session state machines AND-040..048, WIN-040..052; platform glue AND-050..059, WIN-060..075 |
| 3 | UI AND-060..075 (against fakes), WIN-080..084 (tray, window), flow tests AND-080..087, WIN-090..097 |
| 4 | integration: AND-090, WIN-098, XOP-001..004 (real Mac host, iPhone, local relay) |
| 5 | LATER features, in the order listed under each section |

Critical path: SPEC-001..009 -> AND-001/WIN-001 -> AND-010..016 + WIN-010..016 -> AND-040 + WIN-040 ->
AND-050/051 + WIN-060/061 -> AND-090 (M1) -> WIN-064..066 -> WIN-098 (M2) -> XOP-002 -> relay tasks -> files -> agents.

## SPEC and CI (foundation)

SPEC-001 | done | foundation | S : protocol.md part 1, transport, framing, roles, handshake, pairing
Port: `Framing.swift`, `Handshake.swift`, `ClientSession+Handshake.swift`, `HostSession+Handshake.swift`, `PairingSAS.swift`, `PairingPayload.swift`.
Owns: `docs/protocol.md` (sections 1 to 4). Deps: none.
Done: every constant and byte layout in plan section 1.1 to 1.5 appears with its source path; a reviewer can implement framing and SAS from it alone; no em or en dashes in the file.
Commit: Write protocol spec part one: framing, handshake and pairing.

SPEC-002 | done | foundation | S : protocol.md part 2, JSON shapes, commands, capability flags
Port: `RemoteCommand.swift`, `CaptureSource.swift`, `Handshake.swift`, `ProtocolModelTests.swift:341`.
Owns: `docs/protocol.md` (sections 5 to 8, appended after SPEC-001 merges; otherwise write `docs/protocol/json.md` and SPEC-001 links it). Deps: none.
Done: every rule of plan 1.3 stated with an example; every `RemoteCommand` case listed with its JSON; each unverified shape marked UNVERIFIED.
Commit: Write protocol spec part two: JSON shapes, commands and capability flags.

SPEC-003 | done | foundation | S : protocol.md part 3, video and audio lanes
Port: `VideoWire.swift`, `VideoDatagram*.swift`, `VideoKeySchedule.swift`, `VideoFallback.swift`, `VideoReplayWindow.swift`, `ClientSession+DirectPath.swift`.
Owns: `docs/protocol/video.md`. Deps: none.
Done: header layouts, HKDF parameters, nonce rule, chunk header, replay window, fallback constants, direct probe cadence documented with sources.
Commit: Write protocol spec part three: video lanes, sealing and fallback.

SPEC-004 | done | foundation | S : protocol.md part 4, relay signalling
Port: `relay/src/protocol.rs`, `RelayProtocol.swift`, `RelayDeviceProof.swift`, `tcp_relay.rs`, `udp_relay.rs`.
Owns: `docs/protocol/relay.md`. Deps: none.
Done: both message sets with JSON examples, proof payload strings, token handshake, error codes seen in `signalling.rs`.
Commit: Write protocol spec part four: relay signalling and token handshake.

SPEC-005 | done | foundation | S : key maps
Port: `InputEncoding.swift`, `MediaKey` in `RemoteCommand.swift`, `apple/MacCastHost/Input/InputInjector+Events.swift`.
Owns: `docs/protocol/vectors/keymap.json`, `docs/protocol/keymap.md`. Deps: none.
Done: macOS keycode to Windows scancode and VK table, Android `KeyEvent` code to macOS keycode table, modifier mapping rules; JSON parses (`python3 -m json.tool`).
Commit: Add the keycode map between macOS, Windows and Android.

SPEC-006 | done | foundation | S : message vectors
Port: `Handshake.swift`, `RemoteCommand.swift`, `CaptureSource.swift`, `AgentWire.swift`, `TerminalWire.swift`, existing literals in `apple/RemoteCore/Tests/RemoteCoreTests`.
Owns: `docs/protocol/vectors/messages.json`. Deps: SPEC-002.
Done: one JSON file of `{name, kind, json}` cases covering clientHello, serverHello, every command, catalog, config, ping; literal cases copied from the Swift tests are flagged `source: swift-test`.
Commit: Add JSON message vectors for the control channel.

SPEC-007 | done | foundation | S : crypto vectors
Port: `PairingSAS.swift`, `VideoKeySchedule.swift`, `VideoDatagramSealer.swift`, `RelayDeviceProof.swift`; fixed values in `PairingSASTests.swift`, `VideoDatagramTests.swift`, `PairingProofTests.swift`.
Owns: `docs/protocol/vectors/crypto.json`, `docs/protocol/vectors/README.md`. Deps: SPEC-001.
Done: SAS code, commitment, proof, HKDF output, one sealed datagram, replay window sequence; each value either copied from a Swift test or computed by a script in `docs/protocol/vectors/tools/` and marked `source: computed, not yet confirmed by Swift`.
Commit: Add crypto and pairing test vectors.

SPEC-008 | done | foundation | S : wire vectors
Port: `Framing.swift`, `VideoWire.swift`, `VideoFallback.swift`.
Owns: `docs/protocol/vectors/wire.json`. Deps: SPEC-003.
Done: framed bytes (hex) for several kinds, split and coalesced delivery cases, video frame header, audio header, chunk sequences with loss and reordering.
Commit: Add framing, video frame and chunk vectors.

SPEC-009 | done | foundation | S : relay vectors
Port: `RelayProtocolTests.swift`, `relay/tests`.
Owns: `docs/protocol/vectors/relay.json`. Deps: SPEC-004.
Done: client and server relay messages byte exact (sorted keys), token hex cases including the invalid ones.
Commit: Add relay signalling vectors.

SPEC-010 | todo | foundation | S : Swift exporter for vectors (touches apple/)
Port: `apple/RemoteCore/Tests`. Owns: a new test file under `apple/RemoteCore/Tests/RemoteCoreTests/` writing the vector files. Deps: SPEC-006..009.
Done: `cd apple/RemoteCore && swift test --filter VectorExport` regenerates files identical to the checked in ones. BLOCKED until the owner allows edits in `apple/` (see Needs the user).
Commit: Generate the protocol vectors from the Swift implementation so drift shows as a diff.

SPEC-011 | later | S : protocol version policy note
Reason: owner decision on lockstep versions (plan section 10 question 2). Owns `docs/protocol/versioning.md`.

CI-001 | todo | foundation | S : android workflow
Owns: `.github/workflows/android.yml`. Deps: AND-001.
Done: paths `android/**`, `docs/protocol/**`; runs `./gradlew :core:wire:test :core:session:test lint assembleDebug`; YAML parses.
Commit: Add the Android CI workflow with path filters.

CI-002 | todo | foundation | S : windows workflow
Owns: `.github/workflows/windows.yml`. Deps: WIN-001.
Done: paths `windows/**`, `docs/protocol/**`; Linux job runs fmt, clippy and `cargo test -p peering-wire -p peering-core`; windows-latest job runs `cargo build --workspace`.
Commit: Add the Windows CI workflow with path filters.

CI-003 | later | S : add `docs/protocol/**` to `swift.yml` paths. Owns `.github/workflows/swift.yml`. Deps: SPEC-010.

## Relay (REL)

REL-001 | done | parallel-safe | S : raise the notify token limit
Port: `relay/src/signalling.rs:871`. Owns: that check and a test in `relay/tests/` (new file `notify_limits.rs`). Deps: none.
Done: a 330 hex character token passes, a 2000 character one is refused with `invalid`; `cd relay && cargo test --locked` green.
Commit: Allow longer device tokens so FCM tokens fit in notifyDevice.

REL-002 | done | parallel-safe | S : push sender trait and token kind detection
Port: `relay/src/apns.rs`. Owns: new `relay/src/push.rs` (trait, `token_kind(hex) -> Apns|Fcm`). Deps: none.
Done: unit tests: 32 byte hex is APNs, hex of `fcm:`+text is FCM, garbage is APNs; `cargo test --locked`.
Commit: Add push token kind detection ahead of FCM support.

REL-003 | todo | parallel-safe | S : FCM OAuth token minting
Owns: new `relay/src/fcm_auth.rs`. Deps: REL-002.
Done: service account JSON parsed, RS256 JWT built with `ring`, 45 minute cache, tested with a generated key and a fake clock (no network).
Commit: Mint Google OAuth tokens for FCM from a service account.

REL-004 | todo | parallel-safe | S : FCM sender
Owns: new `relay/src/fcm.rs`. Deps: REL-003.
Done: builds the HTTP v1 body (notification plus data keys `hostId`, `source`, `agentSessionId`, `agentApprovalId`, `category`), unit tested; transport behind a trait with a fake.
Commit: Send pushes to Android devices through FCM HTTP v1.

REL-005 | todo | integration | S : route notifyDevice by token kind
Owns: `relay/src/signalling.rs` notify branch, `relay/src/config.rs` (env `PEERINGD_FCM_PROJECT_ID`, `PEERINGD_FCM_SERVICE_ACCOUNT`), `relay/tests/push_routing.rs`. Deps: REL-001, REL-002, REL-004.
Done: e2e test with fake senders proves FCM token reaches FCM and APNs token reaches APNs; no env set means FCM disabled and iOS path unchanged; `cargo test --locked`.
Commit: Route notifyDevice to APNs or FCM by token kind.

REL-006 | todo | parallel-safe | S : Play verdict model and cache (live Play calls need the owner's Google credentials: Needs the user; build against the trait and fakes)
Port: `storekit.rs` (Resolved, Trust, ReceiptCache). Owns: new `relay/src/playbilling.rs` (pure types, mapping product id to Plan, per session cache). Deps: none.
Done: unit tests mirror the storekit rejection table: unknown product, expired, not matching device binding, all end at Free.
Commit: Model Play purchase verdicts and their per session cache.

REL-007 | todo | parallel-safe | S : Play API client
Owns: new `relay/src/play_api.rs`. Deps: REL-003, REL-006.
Done: request building and response parsing unit tested against saved JSON samples; transport behind a trait; endpoints confirmed against current Google docs and noted in the module header.
Commit: Query the Google Play Developer API for purchase state.

REL-008 | todo | integration | S : accept Play fields in connectToHost
Owns: `relay/src/protocol.rs` (optional `play_purchase_token`, `play_product_id`), `relay/src/signalling.rs` connect branch, `relay/tests/play_plan.rs`. Deps: REL-006, REL-007.
Done: old messages decode unchanged (existing tests untouched and green); fake verifier yields Pro and unlimited metering; bad token yields free.
Commit: Meter relay time by a verified Play purchase.

REL-009 | later | S : extract `relay-proto` crate shared with the Windows host. Reason: optional refactor after the suite is green.

## Android: scaffold and contracts

AND-001 | done | foundation | S : Gradle scaffold
Owns: `android/settings.gradle.kts`, `android/build.gradle.kts`, `android/gradle/libs.versions.toml`, `android/gradle.properties`, `android/core/wire/build.gradle.kts`, `android/core/session/build.gradle.kts`, `android/README.md` (build commands only). Deps: none.
Done: modules `core:wire`, `core:session` as Kotlin/JVM with kotlinx-serialization, coroutines-test, Turbine; a placeholder test passes; `cd android && ./gradlew :core:wire:test :core:session:test` green (the `app` and `core:platform` modules are added by AND-002 and AND-060).
Commit: Scaffold the Android Gradle project with pure Kotlin core modules.

AND-002 | todo | foundation | S : session interfaces
Owns: `android/core/session/src/main/kotlin/pl/dmq/peering/session/ports/*.kt`. Deps: AND-001.
Done: interfaces with KDoc contracts and in-memory fakes under `src/testFixtures`: `ControlTransport`, `DatagramTransport`, `Signalling`, `SecretStore`, `DeviceIdentity`, `Clock`, `Discovery`, `VideoSink`, `Keystore signer`; one fake round trip test.
Commit: Define the ports the session layer depends on, with fakes.

## Android: pure wire logic (core:wire), all parallel-safe, Deps AND-001 plus the vector task named

AND-010 | done | S : frame codec. Port `Framing.swift`. Owns `core/wire/.../Framing.kt`, test. Deps SPEC-008. Done: decoder handles split, coalesced and oversize frames, unknown kind error, vectors pass. Commit: Add the frame encoder and decoder with the 16 MiB guard.

AND-011 | done | S : Swift enum serializer. Port `MessageCodec`. Owns `core/wire/.../SwiftEnumSerializer.kt`. Deps SPEC-006. Done: encodes and decodes `{"case":{"label":v}}`, `_0`, empty payload cases, optional omission, base64 Data, uppercase UUID, reference-date Date; tests per rule. Commit: Add a serializer base for Swift Codable enums.

AND-012 | done | S : handshake models. Port `Handshake.swift`. Owns `core/wire/.../Handshake.kt`. Deps AND-011, SPEC-006. Done: all hello/pairing/notice/clipboard/ping/error payloads round trip against vectors; missing optional flags read as null. Commit: Add the handshake and pairing message models.

AND-013 | done | S : command models. Port `RemoteCommand.swift`. Owns `core/wire/.../RemoteCommand.kt`. Deps AND-011. Done: every case encodes to the vector; coalescing and critical flags tested. Commit: Add the remote command model with coalescing rules.

AND-014 | done | S : capture source and catalogue models. Port `CaptureSource.swift`. Owns `core/wire/.../CaptureSource.kt`. Deps AND-011. Done: decodes a catalogue with and without optional parts, `CGSize` array form, stable ids. Commit: Add capture source and catalogue models.

AND-015 | done | S : video and audio wire. Port `VideoWire.swift`. Owns `core/wire/.../VideoWire.kt`. Deps SPEC-008. Done: 25 byte frame header and 20 byte audio header encode/decode, truncated and length mismatch errors, config model. Commit: Add the video and audio frame wire format.

AND-016 | done | S : SAS and transcript. Port `PairingSAS.swift`. Owns `core/wire/.../PairingSas.kt`. Deps SPEC-007. Done: commitment, transcript bytes, code, proof, constant time compare match crypto vectors. Commit: Implement short authentication string pairing maths.

AND-017 | done | S : pairing payload parser. Port `PairingPayload.swift`, `PairingPayloadTests.swift`. Owns `core/wire/.../PairingPayload.kt`. Deps none beyond AND-001. Done: host link, code link with secret, bare UUID, six digit codes and each error case. Commit: Parse pairing QR payloads and typed device ids.

AND-018 | done | S : video key schedule and sealer/opener. Port `VideoKeySchedule.swift`, `VideoDatagramSealer.swift`, `VideoDatagramOpener.swift`. Owns `core/wire/.../VideoSealing.kt`. Deps SPEC-007, AND-020. Done: HKDF and ChaCha20-Poly1305 match vectors, counter nonce, tamper rejected. Commit: Seal and open video datagrams with the derived keys.

AND-019 | done | S : replay window. Port `VideoReplayWindow.swift`. Owns `core/wire/.../ReplayWindow.kt`. Deps SPEC-007. Done: reorder accepted, duplicate and too-old rejected, forged jump does not poison (check does not mutate). Commit: Add the datagram replay window.

AND-020 | done | S : chunk encoder and reassembler. Port `VideoFallback.swift:41-180`. Owns `core/wire/.../VideoChunks.kt`. Deps SPEC-008. Done: loss, reorder, newer frame replaces older, nested chunk and oversize errors. Commit: Add video chunking and reassembly.

AND-021 | done | S : fallback policy. Port `VideoFallback.swift:183-282`. Owns `core/wire/.../VideoFallbackPolicy.kt`. Deps SPEC-008. Done: table driven tests for 3 s silence, control health window, repeat interval, return after two pictures, host decline. Commit: Port the video fallback decision rules.

AND-022 | done | S : relay messages. Port `RelayProtocol.swift`. Owns `core/wire/.../RelayMessages.kt`. Deps SPEC-009. Done: sorted-key encoding byte equal to vectors, token hex strictness. Commit: Add relay signalling messages.

AND-023 | done | S : relay proof payloads. Port `RelayDeviceProof.swift`. Owns `core/wire/.../RelayProof.kt`. Deps SPEC-007. Done: payload strings and hex encoding match vectors. Commit: Build relay device proof payloads.

AND-024 | done | S : command coalescer. Port `CommandCoalescer.swift`, `CoalescerTimerTests.swift`. Owns `core/wire/.../CommandCoalescer.kt`. Deps AND-013. Done: mouse move replaced, scroll accumulates, button events never dropped or reordered, virtual clock tests. Commit: Coalesce pointer commands without dropping button events.

AND-025 | done | S : Android key mapping. Port `InputEncoding.swift`. Owns `core/wire/.../KeyMap.kt`. Deps SPEC-005. Done: Android key code to macOS keycode table and modifier bits from vectors; text vs key routing rule tested. Commit: Map Android keys to macOS keycodes.

AND-026 | done | S : trackpad gesture model. Port `CanvasGestureRouting.swift`, `InputTransform.swift`. Owns `core/wire/.../TrackpadModel.kt`. Deps AND-013. Done: pure model from pointer samples to commands: move, tap, two finger tap, scroll, drag, clamping to 0..1. Commit: Turn touch samples into pointer commands.

AND-027 | done | S : AVCC to Annex-B and codec config. Port `VideoRenderer.swift:300-345`. Owns `core/wire/.../AnnexB.kt`. Deps AND-015. Done: in place length rewrite, csd for H.264 and HEVC, malformed length rejected. Commit: Convert length prefixed frames to Annex-B for MediaCodec.

AND-028 | done | S : reconnect ladder and auto quality. Port `VideoReconnect.swift`, `AutoQualityPolicy.swift`, `StreamQualityLimits.swift`. Owns `core/wire/.../Backoff.kt`, `QualityPolicy.kt`. Deps none. Done: ladder steps, exhaustion, tier moves with fake samples. Commit: Port reconnect backoff and automatic quality rules.

AND-030 | todo | S : agent wire models. Port `AgentWire.swift`. Owns `core/wire/.../AgentWire.kt`. Deps AND-011. Done: every request and event decodes from vectors, unknown stream payload does not crash the list. Commit: Add the agent chat wire models.

AND-031 | todo | S : terminal and file wire models. Port `TerminalWire.swift`. Owns `core/wire/.../FileWire.kt` (file and directory parts) and `TerminalWire.kt` (terminal parts). Deps AND-011. Done: directory entry with `permissions` and Date, file contents, ranges, write and operation events decode. Commit: Add terminal and file wire models.

## Android: pure session logic (core:session), Deps AND-002 and the wire tasks named

AND-032 | todo | S : agent transcript reducer. Port `MacCastKit AgentTranscript.swift`, `AgentTranscriptBuffer.swift`. Owns `core/session/.../agent/TranscriptReducer.kt`. Deps AND-030. Done: events fold into rows (user, streamed text, tool call with result, plan, subagent child), replay merge, gaps; tests per event type. Commit: Reduce agent stream events into transcript rows.

AND-033 | todo | S : approval logic. Port `AgentApprovalBody.swift`, `AgentApprovalNotification.swift`. Owns `core/session/.../agent/Approvals.kt`. Deps AND-030. Done: pending approval derivation, choose/allow/deny request building, resolved-elsewhere handling. Commit: Track agent approvals and build their answers.

AND-034 | todo | S : prompt queue and drafts. Port `AgentPromptQueue.swift`, `AgentDraft.swift`. Owns `core/session/.../agent/PromptQueue.kt`. Deps AND-030. Done: queue while working, send on idle, interrupt clears per rules. Commit: Queue prompts while an agent is working.

AND-035 | todo | S : directory listing model. Port `MacCast/Terminal/RemoteDirectory.swift`, `RemoteFileName.swift`. Owns `core/session/.../files/DirectoryModel.kt`. Deps AND-031. Done: breadcrumb from POSIX path including `/C:/` form, sort, hidden filter, executable bit from `permissions`, name validation. Commit: Model remote directory listings and breadcrumbs.

AND-036 | todo | S : file transfer logic. Port `FileDownloadLimits.swift`, `FileReplacement.swift`, `MacSession+FileDownload.swift`. Owns `core/session/.../files/Transfers.kt`. Deps AND-031. Done: ranged read assembly, progress, size limits, write chunk planner, failure events. Commit: Plan file downloads and uploads over the control channel.

AND-040 | todo | S : connection and pairing state machine. Port `ClientSession+Handshake.swift`, `ClientSession.swift` state enum. Owns `core/session/.../connection/ClientStateMachine.kt`. Deps AND-002, AND-010, AND-012, AND-016. Done: states idle to ready via paired and via SAS; version mismatch, pin mismatch, host id mismatch, no pin but alreadyPaired, refusal; Turbine tests over fake transport. Commit: Implement the client handshake and pairing state machine.

AND-041 | todo | S : liveness. Port `ClientSession+Liveness.swift`, `LatencyMeasurement.swift`. Owns `core/session/.../connection/Liveness.kt`. Deps AND-040. Done: one second ping, pong matching by sequence, silence watchdog, latency smoothing with a virtual clock. Commit: Add ping, pong and silence detection.

AND-042 | todo | S : session ready actions and commands. Port `ClientSession+Commands.swift`. Owns `core/session/.../connection/SessionCommands.kt`. Deps AND-040, AND-024. Done: first quality send, catalogue handling, capability guarded sending (no command without declared flag). Commit: Send commands only when the host declared support.

AND-043 | todo | S : video lane manager. Port `ClientSession+Video.swift`, `+VideoFrames.swift`, `+VideoWatch.swift`, `VideoDeliveryRecord.swift`. Owns `core/session/.../video/VideoLanes.kt`. Deps AND-018, AND-020, AND-021, AND-040. Done: key request/grant, open datagrams, route frames from two lanes with independent reassemblers, fallback requests, return to primary; fake lanes. Commit: Manage the primary and control video lanes with fallback.

AND-044 | todo | S : relay connect flow. Port `ClientSession+Connect.swift`, `RelaySignalling.swift`. Owns `core/session/.../relay/RelayConnect.kt`. Deps AND-022, AND-023, AND-040. Done: request session, quota error mapping, host offline, token write then TLS handoff through the port; fake signalling. Commit: Open a relayed session through signalling.

AND-045 | todo | S : direct path prober. Port `ClientSession+DirectPath.swift`, `VideoDatagramSocket+Addressing.swift`. Owns `core/session/.../relay/DirectPath.kt`. Deps AND-043, AND-044. Done: cadence 250 ms x12 then 5 s, rediscovery every 12, state reporting, authenticated source becomes the peer. Commit: Probe for a direct path to the host.

AND-046 | todo | S : source switching state. Port `ChosenSource.swift`, `MacSession+Picture.swift`. Owns `core/session/.../video/SourceSelection.kt`. Deps AND-014, AND-042. Done: choose, resume source on reconnect, config updates owed by pixel size, input transform from the active source. Commit: Track the chosen capture source across switches.

AND-047 | todo | S : agent chat state holder. Port `SessionModel+AgentChat.swift`, `MacSession+Agent*.swift`. Owns `core/session/.../agent/AgentChat.kt`. Deps AND-032..034. Done: list, start, prompt, history/replay requests, approval, interrupt, close through a fake channel. Commit: Drive agent chats from a session state holder.

AND-048 | todo | S : files state holder. Port `SessionModel+FileBrowser.swift`. Owns `core/session/.../files/FileBrowser.kt`. Deps AND-035, AND-036. Done: open scope, list, navigate up, preview request, failure display states with a fake channel. Commit: Drive the file browser from a session state holder.

AND-049 | todo | S : session history and last-activity records. Port `SessionHistory.swift`, `SessionActivity.swift`. Owns `core/session/.../history/SessionHistory.kt`. Deps AND-040. Done: records appended on connect and end, bounded list, serialisation. Commit: Record finished sessions for the Sessions tab.

## Android: platform glue (core:platform, app), thin, no logic

AND-050 | todo | parallel-safe | S : Keystore identity. Port `SelfSignedIdentity.swift`. Owns `android/core/platform/.../identity/*`. Deps AND-002. Done: key generation, certificate, public point export, DER signature, instrumented test documented; JVM test covers the point encoding helper. Commit: Create the device identity in the Android Keystore.

AND-051 | todo | parallel-safe | S : TLS socket factory. Port `TLSConfig.swift`. Owns `.../net/TlsFactory.kt`. Deps AND-050. Done: TLSv1.3 only, client cert, recording trust manager, pin compare, no-delay; JVM test against an in-process TLS server using a generated cert. Commit: Open pinned mutual TLS 1.3 connections.

AND-052 | todo | parallel-safe | S : pin store. Port `PeerPinning.swift`. Owns `.../store/PinStoreImpl.kt`. Deps AND-002. Done: set, get, remove, failed write leaves memory unchanged; tests with a fake file. Commit: Persist host pins in encrypted storage.

AND-053 | todo | parallel-safe | S : NSD discovery. Port `ServiceDiscovery.swift`. Owns `.../net/NsdDiscovery.kt`. Deps AND-002. Done: maps resolved services with TXT id/name/v to hosts; mapper function unit tested. Commit: Discover hosts on the local network with NSD.

AND-054 | todo | parallel-safe | S : relay WebSocket. Owns `.../net/OkHttpSignalling.kt`. Deps AND-022. Done: send/receive of relay messages over a local test WebSocket server in a JVM test. Commit: Connect to relay signalling over OkHttp.

AND-055 | todo | parallel-safe | S : datagram socket. Port `VideoDatagramSocket*.swift`. Owns `.../net/UdpLane.kt`. Deps AND-002. Done: one socket, two destinations, token-only bind and keepalive, loopback test. Commit: Add the unconnected UDP socket for the video lane.

AND-056 | todo | parallel-safe | S : MediaCodec wrapper. Owns `.../video/CodecDecoder.kt`. Deps AND-027. Done: configure from config, queue Annex-B frames, low latency keys, rebuild on new config; the pure configuration builder is unit tested, device test documented. Commit: Wrap MediaCodec for low latency decoding.

AND-057 | todo | parallel-safe | S : video surface composable. Owns `.../video/VideoSurface.kt`. Deps AND-056. Done: SurfaceView host with aspect fit, transform; no tests (UI). Commit: Render decoded video into a SurfaceView.

AND-058 | todo | parallel-safe | S : network callback. Port `NetworkPathWatcher.swift`. Owns `.../net/NetworkWatcher.kt`. Deps AND-002. Done: emits path changes to the session layer; mapper tested. Commit: Report network changes to the session layer.

AND-059 | todo | parallel-safe | S : billing gateway interface and Play adapter. Port `StoreManager.swift`. Owns `.../billing/*`. Deps none (REL-008 only for the live relay check). Done: `BillingGateway` interface (products, purchase, current entitlement as a flow) with a fake used by everything else; Play adapter behind it; state mapping unit tested. The live Play verification needs the owner's accounts (Needs the user). Commit: Wrap Play Billing and expose the purchase for the relay.

## Android: UI (parallel-safe, built against fakes, no UI tests)

AND-060 | todo | foundation | S : app module, Peering theme (tokens from the design rule), navigation shell. Owns `android/app/*` build files, `MainActivity.kt`, `theme/*`, `nav/*`. Deps AND-001. Done: `./gradlew :app:assembleDebug` builds; bottom nav Connect, Sessions, Settings; dynamic color. Commit: Add the Android app shell with Material 3 navigation.
AND-061 | todo | S : connect screen (hosts list, presence, add by id). Port `HostPickerView*.swift`. Owns `feature/connect/ConnectScreen.kt`, `ConnectViewModel.kt`. Deps AND-060, AND-040. Done: view model unit test over fakes (list ordering, presence); builds. Commit: Add the Connect screen with discovered and paired hosts.
AND-062 | todo | S : pairing screens (code entry, scanner, confirm digits). Port `PairingCode*.swift`, `PairingPrompt.swift`. Owns `feature/pairing/*`. Deps AND-060, AND-040, AND-017. Done: view model tests for digit comparison and cancel; builds. Commit: Add the pairing screens with code comparison.
AND-063 | todo | S : remote canvas and gestures. Port `Remote/RemoteCanvas.swift`, `RemoteScreen+Gestures.swift`. Owns `feature/remote/RemoteScreen.kt`, `GestureLayer.kt`. Deps AND-057, AND-026. Done: feeds AND-026 model; builds. Commit: Add the remote screen with touch input.
AND-064 | todo | S : keyboard capture and modifier bar. Port `KeyboardCapture.swift`, `ModifierBar.swift`. Owns `feature/remote/KeyboardBar.kt`. Deps AND-063, AND-025. Done: builds; routing tested in AND-025. Commit: Add the modifier bar and soft keyboard capture.
AND-065 | todo | S : sources sheet (displays). Port `SourcesPanel.swift`. Owns `feature/remote/SourcesSheet.kt`. Deps AND-063, AND-046. Done: view model test maps catalogue to tiles; builds. Commit: Add the source picker sheet for displays.
AND-066 | todo | S : session hub sheet. Port `RemoteScreen+Hub.swift`. Owns `feature/remote/HubSheet.kt`. Deps AND-063. Done: builds. Commit: Add the session hub sheet.
AND-067 | todo | S : agents hub list. Port `Agent/Hub/*`. Owns `feature/agents/HubScreen.kt`. Deps AND-047. Done: view model test of card digest; builds. Commit: Add the agents hub screen.
AND-068 | todo | S : transcript list UI. Port `Agent/Transcript/*`. Owns `feature/agents/TranscriptList.kt`, `MarkdownText.kt`. Deps AND-032. Done: builds. Commit: Render the agent transcript list.
AND-069 | todo | S : approval card. Port `Agent/Approval/AgentApprovalSheet.swift`. Owns `feature/agents/ApprovalCard.kt`. Deps AND-033. Done: builds. Commit: Add the approval card.
AND-070 | todo | S : composer. Port `Agent/Composer/*` (text, permission mode, model menu, interrupt). Owns `feature/agents/Composer.kt`. Deps AND-034. Done: builds. Commit: Add the agent composer.
AND-071 | todo | S : files list UI. Port `Files/FileBrowserPanel*.swift`. Owns `feature/files/FileList.kt`. Deps AND-048. Done: builds. Commit: Add the file browser list.
AND-072 | todo | S : file preview UI (text, image). Port `Files/FilePreviewPanel*.swift`. Owns `feature/files/Preview.kt`. Deps AND-048. Done: builds. Commit: Add file preview for text and images.
AND-073 | todo | S : settings screen. Port `SettingsTab*.swift` (quality, trusted hosts, identity reset, about). Owns `feature/settings/*`. Deps AND-060, AND-052. Done: view model test for forget host; builds. Commit: Add the settings screen with trusted hosts.
AND-074 | todo | S : paywall UI. Port `Store/Paywall*.swift`, `AllowanceSpentView.swift`. Owns `feature/paywall/*`. Deps AND-059. Done: view model test of states; builds. Commit: Add the paywall and relay allowance screens.
AND-075 | todo | S : first run and FAQ. Port `Onboarding/FAQView.swift`, `FirstConnectionScreen.swift` (minimal). Owns `feature/onboarding/*`. Deps AND-060. Done: builds. Commit: Add minimal first run and FAQ screens.
AND-076 | todo | integration | S : wire the app graph. Owns `app/.../AppGraph.kt`. Deps AND-050..055, AND-061. Done: app builds with real platform classes behind the ports. Commit: Assemble the Android dependency graph.

## Android: flow tests (JVM, fake transports, vectors; no UI)

AND-080 | todo | S : pairing flow. Owns `core/session/src/test/.../PairingFlowTest.kt`. Deps AND-040. Done: scripted fake host: SAS match, SAS mismatch, QR secret proof, host refusal, pin recorded only after success. Run `./gradlew :core:session:test --tests '*PairingFlow*'`. Commit: Test the pairing flow end to end with a fake host.
AND-081 | todo | S : connect and reconnect flow. Owns `.../ConnectFlowTest.kt`. Deps AND-040, AND-041, AND-028. Done: LAN connect, drop and ladder, network change, host stopped code stops reconnecting. Commit: Test connect and reconnect behaviour.
AND-082 | todo | S : relay fallback and direct path flow. Owns `.../RelayFlowTest.kt`. Deps AND-043..045. Done: relayed session, silent datagram lane triggers control fallback, host decline repeats, direct path opens and fallback returns. Commit: Test relay fallback and direct path switching.
AND-083 | todo | S : session start and stop flow. Owns `.../SessionLifecycleTest.kt`. Deps AND-042, AND-049. Done: start, pause picture, resume, stop, history recorded. Commit: Test session start and stop.
AND-084 | todo | S : source switching flow. Owns `.../SourceSwitchTest.kt`. Deps AND-046. Done: switch display, config update owed, input transform follows, resume source on reconnect. Commit: Test display switching.
AND-085 | todo | S : agent chat turn with approval flow. Owns `.../AgentTurnFlowTest.kt`. Deps AND-047. Done: start, prompt, stream, approval, allow, turn finished, interrupt, replay after reconnect. Commit: Test an agent turn with an approval.
AND-086 | todo | S : file browse and transfer flow. Owns `.../FilesFlowTest.kt`. Deps AND-048. Done: list, preview, ranged download, failure, upload chunks. Commit: Test file browsing and transfer.
AND-087 | todo | S : permission and error paths. Owns `.../ErrorPathsTest.kt`. Deps AND-040, AND-044. Done: version mismatch message, quotaExceeded, host offline, malformed frames, oversize payload, unknown enum case does not kill the session. Commit: Test error and refusal paths.

## Android: integration

AND-090 | todo | integration | S : Android to the real Mac host over LAN (milestone M1). Owns `android/app/src/androidTest` notes, `docs/plans/interop-android-mac.md`. Deps AND-076, AND-056, AND-063. Done: pair, see the screen, move the mouse on a device; results written down. Needs a device and a Mac host (Needs the user).
Commit: Record the Android to Mac host interop run.

## Android: LATER and SKIP (each keeps an entry)

AND-100 later: terminal emulator and screen (port `Terminal/*`, `TerminalScreen*.swift`). Reason: needs emulator choice (Termux license unverified).
AND-101 later: terminal wire and session state holder. AND-102 later: terminal tabs UI.
AND-103 later: clipboard sync and history (`Remote/Clipboard*.swift`, `ClipboardHistoryPolicy.swift`). Reason: easy wire, low priority.
AND-104 later: audio playback (`RemoteAudioPlayer.swift`, `SessionAudio.swift`); AudioTrack float PCM.
AND-105 later: picture in picture (`SessionPiP.swift`).
AND-106 later: apps and windows source tiles, launch application, thumbnails (`SourcesPanel+Applications.swift`). Reason: Mac host only until Windows window capture exists.
AND-107 later: Spaces and desktops (`SourcesPanel+Desktops.swift`). Reason: Mac only.
AND-108 skip: mosaic (`MosaicOverlay.swift`). Reason: Mac only, flag never declared.
AND-109 skip: virtual display management (`SourcesPanel+VirtualDisplays.swift`). Reason: Mac private API.
AND-110 skip: joystick (`JoystickView.swift`). Reason: not useful on a touch client.
AND-111 later: macros and shortcut sets (`Macro*.swift`, `MacroBar.swift`, `QuickCommands.swift`).
AND-112 later: Wake on LAN (`WakeOnLAN.swift`). Reason: UDP magic packet from hello MACs.
AND-113 later: FCM registration and push display (needs REL-005); Firebase config comes from a gitignored `google-services.json`, with a documented `google-services.example.json` that holds no real keys, and the app runs with push disabled when the file is absent; AND-114 later: approval actions from a notification; AND-115 later: ongoing session notification (the Android answer to Live Activity).
AND-116 skip: widgets, Siri intents, Live Activity (`MacCastWidget`, `PeeringIntents.swift`). Reason: Apple surfaces.
AND-117 skip: SSH servers and SSH terminal (`SSH/*`, `SSHCore`). Reason: separate product, not a Peering host feature.
AND-118 later: agent changes list and file diff (`Agent/Changes/*`); AND-119 later: commit and push sheet; AND-120 later: review inbox and rejection (`Agent/Review/*`); AND-121 later: web preview (`Agent/Preview/*`); AND-122 later: usage sheet; AND-123 later: resumable session import; AND-124 later: slash and mention hints.
AND-125 later: files download to Storage Access Framework, upload picker, edit, rename, delete, folder archive (`Files/*`, `MacSession+FolderUpload.swift`).
AND-126 later: referral invites (`SettingsTab+Invite.swift`, REL referral messages). AND-127 later: analytics with opt-out (`Analytics.swift`). AND-128 later: What's New, tour (`WhatsNew`, `TourOverlay.swift`).
AND-129 later: text focus, field state and pointer report flags (`TextFocus.swift`, `HostPointer.swift`). AND-130 later: device orientation report (virtual displays only, so skip until needed).
AND-131 later: HEVC capability and the `videoCodecs` hello field (needs the Mac host change, Needs the user).
AND-132 later: keyframe request fallback by pause/resume after decode errors.

## Windows: scaffold and contracts

WIN-001 | done | foundation | S : Cargo workspace. Owns `windows/Cargo.toml`, `windows/rust-toolchain.toml`, `windows/crates/peering-wire/{Cargo.toml,src/lib.rs}`, `windows/crates/peering-core/{Cargo.toml,src/lib.rs}`, `windows/README.md`. Deps none. Done: `cd windows && cargo test -p peering-wire -p peering-core` green on a placeholder; crates have no Windows dependency. Commit: Scaffold the Windows host Cargo workspace.

WIN-002 | done | foundation | S : core traits. Owns `windows/crates/peering-core/src/ports/*.rs`. Deps WIN-001. Done: traits `Clock`, `SecretStore`, `Identity`, `ControlStream`, `DatagramSocket`, `Capture`, `Encoder`, `InputSink`, `Catalogue`, `Signalling` with fakes in `peering-core/src/fakes/`, one loopback test. Commit: Define the ports the host core depends on, with fakes.

## Windows: pure wire logic (peering-wire), parallel-safe, Deps WIN-001 plus the vector task

WIN-010 | done | S : frame codec. Owns `peering-wire/src/framing.rs`. Deps SPEC-008. Done: split/coalesced/oversize/unknown kind vectors pass in `cargo test -p peering-wire`. Commit: Add the frame codec with the 16 MiB guard.
WIN-011 | done | S : Swift enum serde helpers. Owns `peering-wire/src/swift_enum.rs`. Deps SPEC-006. Done: (de)serialize `{"case":{...}}`, `_0`, empty payload, optional omit, base64, uppercase UUID, reference-date. Commit: Add serde helpers for Swift Codable enums.
WIN-012 | done | S : handshake models. Owns `peering-wire/src/handshake.rs`. Deps WIN-011. Done: vectors round trip. Commit: Add handshake and pairing message models.
WIN-013 | done | S : command models. Owns `peering-wire/src/command.rs`. Deps WIN-011. Done: every command case from vectors; unknown case returns a typed error not a panic. Commit: Add the remote command model.
WIN-014 | done | S : catalogue and source models. Owns `peering-wire/src/source.rs`. Deps WIN-011. Done: encode catalogue with displays only and `CGSize` array. Commit: Add capture source and catalogue models.
WIN-015 | done | S : video and audio wire. Owns `peering-wire/src/video.rs`. Deps SPEC-008. Done: header encode/decode and errors. Commit: Add the video and audio frame wire format.
WIN-016 | done | S : SAS maths. Owns `peering-wire/src/sas.rs`. Deps SPEC-007. Done: crypto vectors. Commit: Implement short authentication string pairing maths.
WIN-017 | done | S : pairing payload encoder (QR strings). Owns `peering-wire/src/pairing_payload.rs`. Deps none. Done: host link uppercase UUID, code link with hex secret. Commit: Encode pairing QR payloads.
WIN-018 | done | S : key schedule, sealer, opener. Owns `peering-wire/src/sealing.rs`. Deps SPEC-007. Done: vectors, tamper, counter monotonic. Commit: Seal and open video datagrams.
WIN-019 | done | S : replay window. Owns `peering-wire/src/replay.rs`. Deps SPEC-007. Done: same table as Android. Commit: Add the datagram replay window.
WIN-020 | done | S : chunk encoder and reassembler. Owns `peering-wire/src/chunks.rs`. Deps SPEC-008. Done: loss, reorder, newer frame wins. Commit: Add video chunking and reassembly.
WIN-021 | done | S : fallback host side rules (decline when nothing produced, rate cap, probe keyframes every 4 s). Port `VideoStreamer.use(transport:controlPeer:)`, `VideoFallback.swift`. Owns `peering-wire/src/fallback.rs`. Deps SPEC-008. Done: table tests. Commit: Port the host side of video fallback.
WIN-022 | done | S : relay messages. Owns `peering-wire/src/relay_messages.rs`. Deps SPEC-009. Done: byte equal vectors. Commit: Add relay signalling messages.
WIN-023 | done | S : relay proof payloads. Owns `peering-wire/src/relay_proof.rs`. Deps SPEC-007. Done: vectors. Commit: Build relay device proof payloads.
WIN-024 | done | S : keymap macOS to scancode and VK, modifier mapping. Owns `peering-wire/src/keymap.rs`. Deps SPEC-005. Done: table vectors, Command to Ctrl rule. Commit: Map macOS keycodes to Windows scancodes.
WIN-025 | done | S : normalised point to desktop coordinates. Port `InputTransform.swift`. Owns `peering-wire/src/transform.rs`. Deps none. Done: negative origins, DPI scale, clamp. Commit: Map normalised points onto the virtual desktop.
WIN-026 | done | S : Annex-B to AVCC and parameter set extraction. Owns `peering-wire/src/annexb.rs`. Deps WIN-015. Done: NAL splitting, SPS/PPS lift, 3 and 4 byte start codes, keyframe detection. Commit: Convert encoder output to length prefixed frames.
WIN-027 | done | S : quality limits and bitrate default. Port `StreamQualityLimits.swift`, `VideoEncoder.swift:444`. Owns `peering-wire/src/quality.rs`. Deps none. Done: clamps and default formula. Commit: Port stream quality limits.
WIN-028 | done | S : agent wire models. Owns `peering-wire/src/agent.rs`. Deps WIN-011. Done: vectors. Commit: Add the agent chat wire models.
WIN-029 | done | S : terminal and file wire models. Owns `peering-wire/src/files.rs`, `terminal.rs`. Deps WIN-011. Done: vectors. Commit: Add terminal and file wire models.
WIN-030 | done | S : drop policy and send queue (one frame, keyframe wins). Port `VideoDropPolicy`. Owns `peering-wire/src/drop_policy.rs`. Deps WIN-015. Done: tests. Commit: Keep only the newest frame and never drop a keyframe.
WIN-031 | done | S : split the long wire modules into folders with sibling tests.rs. Owns `peering-wire/src/{command,video,relay_messages}/`. Done: test count unchanged. Commit: Split the long wire modules so each file stays readable.

## Windows: core logic (peering-core), Deps WIN-002 plus wire tasks named

WIN-040 | todo | S : host session handshake state machine. Port `HostSession+Handshake.swift`. Owns `peering-core/src/session/handshake.rs`. Deps WIN-010, 012, 016. Done: roles, hello validation, key mismatch, already paired, SAS, approval path, pin only on success; fake stream tests. Commit: Implement the host handshake and pairing state machine.
WIN-041 | todo | S : pairing service (code, secret, approval requests, devices list). Port `PairingApprovalCard.swift`, `HostModel+Events.swift`. Owns `peering-core/src/pairing.rs`. Deps WIN-040. Done: tests for approve, decline, revoke. Commit: Add the pairing service the UI observes.
WIN-042 | todo | S : liveness and reaper. Port `HostServer.swift` reaper. Owns `peering-core/src/session/liveness.rs`. Deps WIN-040. Done: silence ends sessions, any frame counts; timeout value read from the Swift source first. Commit: End sessions whose client went silent.
WIN-043 | todo | S : command dispatch. Port `HostSession+Commands.swift`. Owns `peering-core/src/session/dispatch.rs`. Deps WIN-013, WIN-040. Done: routes commands to ports, rejects input in observe mode, flags honoured. Commit: Dispatch client commands to the host ports.
WIN-044 | todo | S : catalogue service. Port `VideoCoordinator+Catalogue.swift`. Owns `peering-core/src/catalogue.rs`. Deps WIN-014. Done: push after connect, change detection, per session suppression. Commit: Push the display catalogue to each session.
WIN-045 | todo | S : video coordinator (source choice, keyframe on attach, switch). Port `VideoCoordinator*.swift`. Owns `peering-core/src/video/coordinator.rs`. Deps WIN-044, WIN-030. Done: fake capture/encoder: attach forces keyframe, switch sends new config once, idle watchdog only before the first frame. Commit: Coordinate capture and encode for attached clients.
WIN-046 | todo | S : video lane on the host (datagram sender, key grant, control fallback). Port `VideoDatagramLane.swift`, `VideoStreamer*.swift`. Owns `peering-core/src/video/lane.rs`. Deps WIN-018, 020, 021, WIN-045. Done: fake sockets; key request answered; fallback decline. Commit: Send video over the datagram lane with control fallback.
WIN-047 | todo | S : relay registration loop. Port `RelayHostRegistration.swift`. Owns `peering-core/src/relay/registration.rs`. Deps WIN-022, 023. Done: register, 25 s ping, backoff ladder, proof refreshed per attempt, sessionReady callback, notification queue of 16. Commit: Keep the host registered with the relay.
WIN-048 | todo | S : relayed session dial (token write, then TLS server handoff). Owns `peering-core/src/relay/dial.rs`. Deps WIN-047. Done: fake stream shows token written first. Commit: Dial the relay control port when a session is ready.
WIN-049 | todo | S : direct path knocking. Port `VideoDatagramLane.swift` probe parts. Owns `peering-core/src/video/direct.rs`. Deps WIN-046. Done: cadence tests. Commit: Knock for a direct path from the host side.
WIN-050 | done | S : host settings model (port, quality, autostart flag). Owns `peering-core/src/settings.rs`. Deps none. Done: defaults and clamps. Commit: Model host settings.
WIN-051 | todo | S : push token registry. Port `PushTokenStore.swift`. Owns `peering-core/src/push_tokens.rs`. Deps WIN-029. Done: hex of bytes, empty forgets. Commit: Store the push tokens clients register.
WIN-052 | todo | S : file browse service on a fake filesystem with POSIX style virtual paths. Port `TerminalSessionManager+FileBrowsing.swift`, `DirectoryListing.swift`. Owns `peering-core/src/files/browse.rs`. Deps WIN-029. Done: `/` lists drives, `/C:/Users`, `ls` permission string synthesis, read limits, errors. Commit: Serve directory listings and file reads.

## Windows: agent (peering-agent), no Windows API in the logic

WIN-053 | todo | S : Claude stream-json parser. Port `MacCastKit AgentClaudeStream.swift`. Owns `peering-agent/src/claude_stream.rs`, fixtures in `peering-agent/tests/fixtures/claude/`. Deps WIN-028. Done: recorded transcripts produce the events the Swift parser produces (fixtures taken from MacCastKit tests). Commit: Parse Claude Code stream output into agent events.
WIN-054 | todo | S : Claude adapter (spawn args, stdin protocol, approvals over stdio, interrupt). Port `ClaudeCodeAdapter.swift`. Owns `peering-agent/src/claude_adapter.rs`. Deps WIN-053. Done: against a fake child process script; approval round trip. Commit: Drive Claude Code as a child process.
WIN-055 | todo | S : session manager (list, start, history, replay, close, limits). Port `AgentSessionManager*.swift`, `AgentSession.swift`. Owns `peering-agent/src/manager.rs`. Deps WIN-054. Done: fake adapters; snapshot, replay with isLast, three chat limit not enforced. Commit: Manage agent sessions and replay.
WIN-056 | todo | S : agent directory browse. Port `AgentDirectoryBrowser.swift`. Owns `peering-agent/src/browse.rs`. Deps WIN-052. Done: tests. Commit: Browse folders for starting an agent.
WIN-057 | todo | S : binary lookup and environment on Windows. Port `AgentEnvironment.swift`. Owns `peering-agent/src/environment.rs`. Deps none. Done: PATH search with `.exe`/`.cmd` shims on a temp dir tree; cmd shim wrapping rule. Commit: Find agent CLIs on Windows.

## Windows: platform (peering-platform and host), Windows API; tests only for pure mappers

WIN-060 | todo | S : identity and certificate. Owns `peering-platform/src/identity.rs`. Deps WIN-002. Done: P-256 key, `rcgen` cert with the Swift template (CN, O, EKU, validity), point export, DER signature; runs on Linux CI for the portable part. Commit: Create the host identity and certificate.
WIN-061 | todo | S : rustls server config with custom client verifier. Owns `peering-platform/src/tls.rs`. Deps WIN-060. Done: TLS 1.3 only; in-process client test accepts any client cert and exposes its point. Commit: Serve pinned mutual TLS 1.3.
WIN-062 | todo | S : DPAPI secret store. Owns `peering-platform/src/dpapi_store.rs`. Deps WIN-002. Done: round trip (Windows CI job only). Commit: Protect keys and pins with DPAPI.
WIN-063 | todo | S : mDNS advertisement. Owns `peering-platform/src/mdns.rs`. Deps WIN-001. Done: TXT record builder tested; advertise on a loopback in a test. Commit: Advertise the host on the local network.
WIN-064 | todo | S : monitor enumeration and stable ids. Owns `peering-platform/src/monitors.rs`. Deps WIN-014. Done: pure id/rect mapping tested; enumeration on Windows. Commit: List monitors with stable ids.
WIN-065 | todo | S : desktop duplication capture. Owns `peering-platform/src/capture/dda.rs`. Deps WIN-064. Done: grabs frames from a chosen output as D3D11 textures; access-lost recovery; manual run on a Windows machine. Commit: Capture a monitor with desktop duplication.
WIN-066 | todo | S : BGRA to NV12 conversion. Owns `peering-platform/src/encode/convert.rs`. Deps WIN-065. Done: GPU video processor path with a CPU reference test for the maths. Commit: Convert captured frames to NV12 on the GPU.
WIN-067 | todo | S : Media Foundation H.264 encoder. Owns `peering-platform/src/encode/mft.rs`. Deps WIN-066, WIN-026. Done: hardware first then software, low latency attributes, forced keyframe, bitrate change; produces AVCC and config via WIN-026; manual run. Commit: Encode H.264 with Media Foundation at low latency.
WIN-068 | todo | S : SendInput mouse and wheel. Owns `peering-platform/src/input/mouse.rs`. Deps WIN-025. Done: pure event builder tested; injection on Windows. Commit: Inject mouse and wheel input.
WIN-069 | todo | S : SendInput keyboard, Unicode text, release all. Owns `peering-platform/src/input/keyboard.rs`. Deps WIN-024. Done: builder tests, held key tracker releases all on disconnect. Commit: Inject keyboard and text input.
WIN-070 | todo | S : DPI awareness manifest and rc. Owns `host/build.rs`, `host/app.manifest`. Deps none. Done: manifest declares Per-Monitor-V2. Commit: Declare per-monitor DPI awareness.
WIN-071 | todo | S : host binary wiring (tokio runtime, listener, services). Owns `host/src/main.rs`, `host/src/runtime.rs`. Deps WIN-040..048, WIN-061. Done: starts, listens on 51515, advertises. Commit: Wire the host runtime together.
WIN-072 | todo | S : tray icon and menu. Owns `host/src/tray.rs`. Deps WIN-071. Done: builds on Windows. Commit: Add the tray menu.
WIN-073 | todo | S : pairing window (QR, code, devices). Owns `host/src/ui/pairing.rs`. Deps WIN-041, WIN-017. Done: builds. Commit: Show the pairing code and QR.
WIN-074 | todo | S : autostart and firewall helper. Owns `host/src/autostart.rs`, `host/src/firewall.rs`. Deps WIN-071. Done: pure command builders tested. Commit: Start at login and offer a firewall fix.
WIN-075 | todo | S : secure desktop notice. Owns `peering-platform/src/session_state.rs`. Deps WIN-065. Done: detect access lost and lock state, emits the `notice` payload. Commit: Tell the client when the secure desktop blocks capture.

## Windows: flow tests (service level, fake ports, vectors)

WIN-090 | todo | S : pairing flow. Owns `peering-core/tests/pairing_flow.rs`. Deps WIN-040. Done: SAS match/mismatch, QR proof, approval, decline, pin only after success. Run `cargo test -p peering-core --test pairing_flow`. Commit: Test the host pairing flow.
WIN-091 | todo | S : connect, liveness and reconnect flow. Owns `peering-core/tests/connect_flow.rs`. Deps WIN-042. Done: video connection without control session is refused; silence reaped. Commit: Test connection and liveness behaviour.
WIN-092 | todo | S : relay fallback and direct path flow. Owns `peering-core/tests/relay_flow.rs`. Deps WIN-046..049. Done: registration, session dial, key request, fallback and decline, direct knock. Commit: Test relay and direct path behaviour.
WIN-093 | todo | S : session start and stop flow. Owns `peering-core/tests/session_lifecycle.rs`. Deps WIN-045. Done: attach/detach, last client leaves, next client does not inherit source, input released. Commit: Test session start and stop.
WIN-094 | todo | S : display switching flow. Owns `peering-core/tests/switch_flow.rs`. Deps WIN-045. Done: switch emits one config, input transform follows. Commit: Test display switching.
WIN-095 | todo | S : agent chat turn with approval flow. Owns `peering-agent/tests/turn_flow.rs`. Deps WIN-055. Done: fake CLI script, approval allow and deny. Commit: Test an agent turn with an approval.
WIN-096 | todo | S : file browse and transfer flow. Owns `peering-core/tests/files_flow.rs`. Deps WIN-052. Done: browse, read range, errors, path escape refused. Commit: Test file browsing.
WIN-097 | todo | S : permission and error paths. Owns `peering-core/tests/error_paths.rs`. Deps WIN-043. Done: bad version, oversize, unknown command, observe mode. Commit: Test error and refusal paths.
WIN-098 | todo | integration | S : iPhone to the Windows host over LAN (milestone M2). Owns `docs/plans/interop-iphone-windows.md`. Deps WIN-071, WIN-067, WIN-069. Done: pair, picture, mouse on a real iPhone; written up. Needs a device (Needs the user). Commit: Record the iPhone to Windows host interop run.

## Windows: LATER and SKIP

WIN-100 later: window capture with Windows.Graphics.Capture (`window(u32)` HWND source). WIN-101 skip: application capture (`application(pid)` composite). WIN-102 skip: mosaic. WIN-103 skip: Spaces listing and jump by index (undocumented COM). WIN-104 later: Space direction chord (`Ctrl+Win+Left/Right`). WIN-105 skip: virtual display (needs a signed driver). WIN-106 skip: privacy mode brightness (DDC/CI unreliable). WIN-107 later: lock screen command (`LockWorkStation`). WIN-108 later: keep awake (`SetThreadExecutionState`). WIN-109 skip: lid close, wake schedule, sleep control. WIN-110 later: Wake on LAN MACs in hello. WIN-111 later: clipboard (text, then PNG). WIN-112 later: audio loopback capture (WASAPI, float32 frames). WIN-113 later: terminal sessions (ConPTY, `portable-pty`, `TerminalSessionManager*.swift`). WIN-114 later: Claude terminal hooks (`Terminal/Hooks`). WIN-115 later: Codex and OpenCode adapters (`CodexAdapter.swift`, `OpenCodeAdapter.swift`, `PerTurnAdapter.swift`) and their parsers. WIN-116 later: agent changes, git, commit, push (`AgentChanges*.swift`, `AgentGit*.swift`). WIN-117 later: resumable session import (`ClaudeSessionLibrary.swift`). WIN-118 later: file write, rename, delete, folder archive. WIN-119 later: push on approval needed (`notifyDevice` forwarding, depends on REL-005). WIN-120 later: web preview proxy (`PreviewProxyService.swift`). WIN-121 later: updates (Velopack or WinSparkle, unverified). WIN-122 todo: unsigned installer build and README note about the SmartScreen warning (owner decision 6; no signing). WIN-128 todo: documented build-from-source steps in `windows/README.md`. WIN-123 skip: text focus, field state, pointer report (UI Automation). WIN-124 later: HEVC negotiation (read `videoCodecs` from clientHello; clients that do not declare it get H.264). WIN-131 later: HEVC encoder capability probe through Media Foundation. WIN-132 later: HEVC encode path with VPS/SPS/PPS config, H.264 always the fallback. Decision and comparison in plan section 10. WIN-129 later: agents inside WSL (optional future feature, native only in v1). WIN-125 later: `uiAccess` build for elevated windows. WIN-126 skip: widget, analytics, onboarding windows. WIN-127 later: Windows host resource sampler and activity log view (`HostResourceSampler.swift`, `HostDiagnostics.swift`).

## Cross platform interop (integration)

XOP-001 | todo | integration | S : Rust test client against the real Mac host and the local relay. Owns `windows/crates/peering-testclient/*`. Deps WIN-040, WIN-061. Done: connects to a Mac host on LAN and pairs (manual), prints a catalogue. Needs a Mac host running (Needs the user). Commit: Add a headless test client for interop runs.
XOP-002 | todo | integration | S : Android to Windows host over LAN. Owns `docs/plans/interop-android-windows.md`. Deps AND-090, WIN-098. Done: written run.
XOP-003 | todo | integration | S : both clients against a local relay (`cargo run` in `relay/`). Owns `docs/plans/interop-relay.md`. Deps AND-082, WIN-092. Done: relayed session, fallback observed, written run.
XOP-004 | todo | integration | S : full matrix run (Android/iPhone x Mac/Windows x LAN/relay). Owns `docs/plans/interop-matrix.md`. Deps XOP-002, XOP-003.

## Needs the user

* Mac host patch: review and apply `docs/plans/mac-host-patch.md` (reading `videoCodecs`, sending `hostPlatform`). `apple/` is not touched by these agents.
* SPEC-010 needs permission to add one test file under `apple/RemoteCore/Tests/` (the Swift vector exporter). Until then vectors are hand-derived and marked as such.
* AND-090, WIN-098, XOP-001..004 need a device or a running Mac host.
* Play Billing: Google Play Console product setup and a service account for REL-007 live verification. Everything else builds against the `BillingGateway` fake.
* Firebase: the owner provides `google-services.json` later; FCM tasks work without it.
* Play upload key (releasing the Android app).
