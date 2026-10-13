# Windows host feature parity

Audit of `windows/` (host, `peering-core`, `peering-platform`, `peering-wire`, `peering-net`, `peering-agent`) against the Mac host
(`apple/MacCastHost`) and against what the iPhone and Android clients send and expect (`docs/protocol.md`, `apple/RemoteCore`,
`android/core`). Read-only audit, 2026-10-13, by reading and grepping the Rust source. Nothing was run: per `windows/README.md` the
Windows-only code has not yet run on a Windows machine, so PRESENT means "the code is there and wired", not "seen working".

Classes:

* PRESENT: built and wired in the runtime.
* PARTIAL: built in part; the line says what is missing.
* MISSING: the Mac has it, the Windows host does not, and it can be built on Windows.
* N/A: macOS only. The line names the Windows equivalent if there is one.

Line format: `[CLASS] item. Win: file:line. Mac: reference.`

## Summary

The counts are as audited on the first day. The lines carry the statuses of both passes, and the last two sections list what changed.

Area sections 1 to 13 and 16 to 20 (129 items): PRESENT 71, PARTIAL 19, MISSING 31, N/A 8.

Protocol facing sections 14 and 15 (38 items, flags, commands and frame kinds; they restate features that also appear above, so they are counted apart): PRESENT 22, PARTIAL 9, MISSING 6, N/A 1.

| Section | Present | Partial | Missing | N/A |
|-|-|-|-|-|
| 1. Pairing | 10 | 1 | 0 | 0 |
| 2. TLS identity and pinning | 6 | 0 | 0 | 0 |
| 3. LAN advertisement | 2 | 3 | 0 | 0 |
| 4. Relay registration and tunnel | 5 | 0 | 2 | 0 |
| 5. Direct path and hole punching | 1 | 1 | 0 | 0 |
| 6. Video capture and encode | 7 | 6 | 7 | 2 |
| 7. Audio | 0 | 0 | 1 | 0 |
| 8. Input | 6 | 2 | 1 | 2 |
| 9. Pointer, text focus and field state reports to the phone | 1 | 0 | 1 | 0 |
| 10. Clipboard | 3 | 0 | 0 | 0 |
| 11. File browsing and transfer | 6 | 1 | 1 | 1 |
| 12. Terminals | 6 | 1 | 0 | 1 |
| 13. Coding agents | 5 | 1 | 6 | 0 |
| 14. Handshake capability flags | 12 | 2 | 3 | 0 |
| 15. Messages and commands the phone can send | 10 | 7 | 3 | 1 |
| 16. Live Activity, notices and presence | 3 | 0 | 1 | 0 |
| 17. Power, lock, login, update | 4 | 0 | 3 | 1 |
| 18. Host UI | 2 | 1 | 4 | 1 |
| 19. Analytics, crash reporting, localisation | 0 | 0 | 4 | 0 |
| 20. Resilience | 4 | 2 | 0 | 0 |

Headlines (as audited; the counts and the item lines above carry the fixes of 2026-10-13, and the last section says what changed):

* The Windows host is a working core (pairing, TLS pinning, LAN and relay reach, one display as H.264, mouse and keyboard, shells,
  Claude chat, read-only file browsing). It has nothing from the "second tier" of the Mac host: no clipboard, audio, cursor in the picture,
  window or application sources, thumbnails, mosaic, virtual displays, privacy mode, Spaces, keep awake, auto update, analytics or localisation.
* Nothing is advertised falsely in a way that breaks a phone. Several claims need care (see "Advertised but not handled" below): `supportsFileBrowser` is true while
  writes fail, `supportsLockScreen` is emitted but read by nobody, and agent facts that the Mac withholds from clients without the matching
  flag are sent unconditionally.
* The iPhone has no gating on `hostPlatform` (a grep of `apple/MacCast` and `RemoteCore` finds only a telemetry read), so it is expected to offer
  Mac-only controls against a Windows host, and the host drops those commands without a reply. Android hides them (`HostCapability.kt:47`).

## 1. Pairing

* [PRESENT] Six digit code by commitment, reveal and SAS. Win: `crates/peering-core/src/session/handshake/pairing.rs:24`, `crates/peering-wire/src/sas.rs`. Mac: `Network/HostSession+Pairing.swift`.
* [PRESENT] QR for the host identity and for the code with the secret (proof skips approval). Win: `crates/peering-wire/src/pairing_payload.rs:31,36`, `host/src/ui/pairing.rs:29`, `host/src/ui/qr.rs`. Mac: `HostStatusView+Connect.swift`, `PairingCodeFormatting.swift`.
* [PRESENT] Typed code without proof asks the PC user to approve. Win: `crates/peering-core/src/pairing.rs:118`, `host/src/ui/pairing.rs:45`. Mac: `Pairing/PairingApprovalCard.swift`.
* [PRESENT] Approval queue is capped and a refusal is delivered to the waiting session. Win: `host/src/runtime/connection/actions.rs:35`. Mac: `Network/HostServer+Pairing.swift`.
* [PRESENT] Pairing offer takeover: the same address, or an offer older than 120 s, may replace a stale holder. Win: `crates/peering-core/src/pairing.rs:52,82`. Mac: `Network/HostServer+Admission.swift:46` (`evictStalePairingHolder`).
* [PRESENT] Pre-authentication connection cap per address. Win: `host/src/runtime/pre_auth.rs:18`, `crates/peering-core/src/admission.rs`. Mac: `Network/HostServer+Admission.swift:35`.
* [PRESENT] Forget one device, and it ends that device's live sessions and releases input. Win: `host/src/runtime/control.rs:158,210`. Mac: `HostStatusView+Devices.swift:158`.
* [PARTIAL] Reset paired devices. Win: `host/src/runtime/control.rs:171`, `host/src/ui/pairing.rs:71`. It is offered only when the stored list is unreadable; there is no "Forget all" for a healthy list. Mac: `HostStatusView+Devices.swift:15` (`unpairAll`).
* [PRESENT] Paired list sealed with DPAPI and recoverable when corrupt. Win: `host/src/runtime/pins.rs:27,64`, `crates/peering-core/src/paired_list.rs:25`. Mac: keychain pin store.
* [PRESENT] `lostPairing` re-pair path. Win: `crates/peering-wire/src/handshake.rs:70,81`, `crates/peering-core/src/session/handshake.rs:163`. Mac: `HostSession+Handshake.swift`.
* [PRESENT] `mac_addresses` withheld until paired. Win: `crates/peering-core/src/session/handshake.rs:193`. The list itself is empty, see section 16. STATUS 2026-10-13: The list is now filled, see section 16.

## 2. TLS identity and pinning

* [PRESENT] TLS 1.3 only, host as server, also over the relay. Win: `crates/peering-net/src/tls.rs:42,49`. Mac: `Network/PeerConnection.swift`, `TLSConfig.swift`.
* [PRESENT] Long-term P-256 key and self-signed certificate; the key is sealed with DPAPI. Win: `crates/peering-net/src/identity.rs:56,131`, `crates/peering-platform/src/dpapi.rs:58`. Mac: `SelfSignedIdentity.swift`.
* [PRESENT] Mutual TLS accepting any client certificate, trust decided by pin afterwards, constant time compare. Win: `crates/peering-net/src/tls/client_verifier.rs:28`, `crates/peering-core/src/session/handshake.rs:160,241`. Mac: `PeerPinning.swift`, `ConstantTime.swift`.
* [PRESENT] Client key taken from the certificate, never a message; key mismatch closes. Win: `crates/peering-net/src/tls.rs:80`, `crates/peering-core/src/session/handshake.rs:158`. Mac: `HostSession+Handshake.swift`.
* [PRESENT] Install-bound DPAPI entropy, older secrets re-sealed. Win: `crates/peering-platform/src/dpapi/entropy.rs`, `crates/peering-core/src/install_entropy.rs`. Mac: keychain access groups.
* [PRESENT] `TCP_NODELAY` and keepalive on accepted sockets. Win: `host/src/runtime/listener.rs:6`, `crates/peering-net/src/socket.rs:16`. Mac: `PeerConnection.swift`.

## 3. LAN advertisement

* [PRESENT] DNS-SD `_remotedesktop._tcp` with `id`, `name`, `v` TXT keys. Win: `crates/peering-net/src/mdns.rs:9,41`, `host/src/runtime/advertise.rs:8`, `host/src/runtime/serve.rs:54`. Mac: `Network/HostServer.swift` (Bonjour).
* [PARTIAL] Withdraw the advertisement while a client is connected. `Advertiser::set_connected_clients` exists (`crates/peering-net/src/mdns.rs:96`) but nothing calls it, so the host stays advertised during a session. Mac: withdraws.
* [PARTIAL] Re-advertise on network change or wake. Win: no observer; the registry is created once at start (`host/src/runtime/serve.rs:54`). Mac: `Network/NetworkChangeObserver.swift`.
* [PARTIAL] Firewall. Win: `host/src/firewall.rs:15,20` adds an inbound TCP rule and an mDNS rule on private networks, only after the user presses Fix firewall; the UDP video and probe sockets are not covered. Mac: not needed.
* [PRESENT] Choosing the port. Win: fixed `DEFAULT_PORT` (`host/src/main.rs:65`), `HostSettings.port` is not read. Mac: `HostStatusView+Settings.swift` `portRow`. STATUS 2026-10-13: Fixed: the port comes from `settings.txt` (`host/src/main.rs`, `host/src/settings_store.rs`); the window has no control for it, so it is changed in the file. Not run on Windows.

## 4. Relay registration and tunnel

* [PRESENT] WebSocket registration with device proof, reconnect ladder with jitter, clock skew reported. Win: `host/src/runtime/relay.rs`, `crates/peering-core/src/relay/registration.rs:142,193,208`, `host/src/runtime/control.rs:23`. Mac: `Network/RelayHostRegistration.swift`.
* [PRESENT] Dial the relay control port on `sessionReady` and serve TLS over the splice, with a dial cap. Win: `host/src/runtime/relay.rs:168`, `crates/peering-core/src/relay/dial.rs`. Mac: `Network/HostServer+Relay.swift`.
* [PRESENT] Relayed UDP video lane with control stream fallback. Win: `host/src/runtime/relay_lane.rs:28`, `crates/peering-core/src/video/lane.rs:53,94`, `host/src/runtime/video_requests.rs:16,38`. Mac: `Video/VideoDatagramLane.swift`.
* [PRESENT] `registerPushToken` stored and `notifyDevice` queued for the relay. Win: `crates/peering-core/src/terminal/manager.rs:89`, `host/src/runtime/notifications.rs`, `host/src/runtime/relay.rs:160`. Mac: `Terminal/PushTokenStore.swift`.
* [PRESENT] Relay on or off. Win: always on (`host/src/main.rs:55`); `HostSettings.relay_enabled` is not wired. Mac has a relay toggle in settings. STATUS 2026-10-13: Fixed: the window has a switch, `relay_switch.rs` starts and stops the registration live and the choice is saved. Not run on Windows.
* [MISSING] `hostPresence` handling. Win: parsed and ignored (`crates/peering-core/src/relay/registration.rs:184`). Mac: `LiveActivity/PhonePresenceRegistry.swift` uses it to know whether a phone is looking. Needed for presence aware pushes.
* [MISSING] `notifyActivity` (Live Activity pushes, section 16). The message type exists in `crates/peering-wire/src/relay_messages/mod.rs:97` but nothing builds one.

## 5. Direct path and hole punching

* [PRESENT] Knock schedule, relay `requestPeerAddress`, authenticated probe opens the path, keepalive. Win: `crates/peering-core/src/video/direct.rs:8,57,75`, `host/src/runtime/relay_lane.rs:97,112,137`, `host/src/runtime/peer_address.rs:46`. Mac: `ClientSession+DirectPath.swift` counterpart in `Video/VideoDatagramLane.swift`.
* [PARTIAL] Video socket model. Win: a UDP socket per relayed session. Mac: one unconnected socket on one local port with two destinations. Not yet verified against a real relay or on Windows (`windows/README.md`).

## 6. Video capture and encode

* [PRESENT] Display capture through Desktop Duplication, reacquired after access loss. Win: `crates/peering-platform/src/dda/sys.rs`, `crates/peering-platform/src/dda.rs:28,80`. Mac: `Capture/ScreenCaptureSourceResolver.swift`.
* [PRESENT] Display sources and the display catalogue, primary first, under the 64 KiB budget. Win: `crates/peering-core/src/catalogue.rs:49`, `host/src/runtime/video.rs:111`. Mac: `Video/VideoCoordinator+Catalogue.swift`.
* [PRESENT] H.264 encode through Media Foundation, hardware MFTs before software, CBR, low latency. Win: `crates/peering-platform/src/mft/sys.rs:80,90`, `mft/candidates.rs:11`, `mft/config.rs:11`. Mac: `Capture/VideoEncoder.swift`.
* [PRESENT] Keyframe on attach, resume, resync and source change; the phone's pause then resume nudge works. Win: `crates/peering-core/src/video/coordinator.rs:113,163`, `host/src/runtime/connection/lifecycle.rs:46`. Mac: `Video/VideoCoordinator+Clients.swift`.
* [PRESENT] Pause (`setVideoEnabled`) and background (`clientState`) stop encoding and relax liveness. Win: `crates/peering-core/src/video/coordinator.rs:163,173`, `host/src/runtime/ready.rs:62`, `crates/peering-core/src/session/liveness.rs:76`. Mac: `HostSession+Commands.swift:30`.
* [PRESENT] Bitrate clamp to 100000 kbps, per session ceiling for the fallback lane, lowest wins. Win: `crates/peering-wire/src/quality.rs:3,10`, `host/src/runtime/video_requests.rs:55`. Mac: `StreamQualityLimits.swift`.
* [PARTIAL] Frame rate. Win: snaps to 15, 30 or 60 (`crates/peering-core/src/settings.rs:5,93`), so the protocol's 15 to 120 range is quantised and 120 is capped at 60; the window choice is not saved (`windows/README.md`). Mac: `frameRateRow`, `Capture/StreamPacer.swift`. STATUS 2026-10-13: The window choice is now saved and applied at the next start.
* [PARTIAL] Capture recovery and supervision. Win: retry delays 0.5 s to 15 s, stall probe at 30 s, device rebuild after two encoder rebuilds, a pass abandoned after 10 s (`crates/peering-core/src/video/recovery.rs:10,12,16`, `crates/peering-core/src/supervision.rs:7`, `host/src/runtime/video_handle.rs:93`). Missing: the wedged driver thread leaks until exit (`windows/README.md`). Mac: `Capture/CaptureRecovery.swift`.
* [PARTIAL] Secure desktop and lock screen. Win: a notice "This PC is locked" and recapture after access loss (`crates/peering-platform/src/session_state.rs:43`, `dda.rs:28`). The host runs `asInvoker` (`host/app.manifest`), so input into an elevated window or a UAC prompt is dropped by UIPI; there is no UI access path. Mac: `OffDesktopInputGate.swift` is the nearest analogue.
* [PARTIAL] Window sources. Win: `set_source` accepts display ids only and errors with `UnsupportedSource` (`crates/peering-core/src/video/coordinator/source.rs:53`); the phone gets `sourceUnavailable`. Buildable with Windows.Graphics.Capture. Mac: `Capture/CaptureSourceResolver.swift`. STATUS 2026-10-13: Not done: Windows.Graphics.Capture is not a dependency, and a second capture path (capture item, frame pool, window and application catalogue with icons) cannot be exercised without a Windows machine. The phone is told in a notice (`displayDisconnected`), not an `error`, which ends an iPhone session. STATUS 2026-10-13 (second pass): Fixed for windows: `set_source` takes a window id, the capture is Windows.Graphics.Capture (`crates/peering-platform/src/wgc/sys.rs`, `window_list/sys.rs`), input is mapped into the window, and a closed window returns the picture to the primary display (`video/coordinator/recover.rs`). Type checked for the Windows target, not run. Application sources are not built.
* [MISSING] Application sources (all windows of a process composited). Same site as above. Mac: `ScreenCaptureSourceResolver+Filters.swift`. STATUS 2026-10-13: Not done, with window sources. STATUS 2026-10-13 (second pass): Not done, and not buildable the way the Mac does it: Windows.Graphics.Capture captures one window or one screen, not the windows of a program together. A catalogue entry for an application would not be capturable, so none is listed.
* [PARTIAL] Catalogue of windows, running applications and installed applications with icons. Win: `catalogue.rs:61` fills `displays` only. Mac: `ScreenCaptureSourceResolver+Catalogue.swift`, `+Descriptors.swift`. STATUS 2026-10-13: Not done, with window sources: entries that cannot be captured would not be honest. STATUS 2026-10-13 (second pass): The catalogue lists windows (`catalogue.rs`, `window_list.rs`), each only if the system accepts it for capture when it is listed. Applications, installed applications and icons are not listed.
* [PARTIAL] Mosaic source. Win: dropped before dispatch with `IgnoreReason::MosaicSource`, no reply (`crates/peering-core/src/session/dispatch.rs:101`); `supportsMosaic` correctly not set. Mac: `Capture/MosaicCompositor.swift`, `MosaicPlan.swift`. STATUS 2026-10-13: Now answered with a notice that lapses after 6 s (`refusal.rs`); `supportsMosaic` stays unset.
* [MISSING] Source thumbnails and refresh or watch commands. Win: `refreshSourceThumbnails` and `watchSourceThumbnails` fall to `NotSupportedHere` (`dispatch.rs:114`); `supportsSourceThumbnails` correctly not set. Mac: `Capture/SourceThumbnailCache.swift`. STATUS 2026-10-13 (second pass): Not done: a thumbnail per window needs a captured frame encoded to PNG for every listed window; `supportsSourceThumbnails` stays unset.
* [MISSING] HEVC. Win: H.264 only, `ClientHello.videoCodecs` is stored but never read (`crates/peering-core/src/session/handshake.rs:56,168`, `mft/config.rs:11`). Mac: `Capture/VideoCodec.swift`, codec row. Clients fall back to H.264, so this costs bandwidth only.
* [MISSING] Capture resolution setting (scale down for a slow link). Win: always the display's native size (`coordinator/source.rs:65`). Mac: `HostModel+Capture.swift:6`.
* [PRESENT] Cursor in the picture. Win: Desktop Duplication frames carry no cursor and nothing composites one (`dda/sys.rs:144` only releases pointer-only frames); `supportsPointerReport` is never answered. Mac: `Capture/CursorOverlay.swift`. UNVERIFIED on a device. STATUS 2026-10-13 (second pass): Fixed: the duplication delivers the pointer shape and position, and `dda/sys/cursor.rs` blends it into a GPU copy of the frame (pure shapes, clipping and blending in `crates/peering-platform/src/cursor.rs`); a pointer-only change makes a frame. Setting `cursorInPicture`. Not run on Windows; an HDR display leaves the pointer out.
* [N/A] Virtual displays (`addVirtualDisplay`, `removeVirtualDisplay`, `renameVirtualDisplay`, `reportDeviceOrientation`). Win: dropped silently (`dispatch.rs:93`); flags not set. Mac: `Display/VirtualDisplay.swift` (private CGVirtualDisplay). Windows equivalent: an indirect display driver, which needs a signed kernel-adjacent driver; treat as a separate project.
* [N/A] Spaces (`switchSpace`, `switchToSpace`, `refreshSpacePreviews`, `spaceInfo`). Win: dropped silently (`dispatch.rs:92`). Mac: `SpaceReader.swift`, `Capture/SpacePreviewCache.swift`. Windows equivalent: virtual desktops via the undocumented `IVirtualDesktopManager`, or Win+Ctrl+Left and Right chords through `SendInput`. STATUS 2026-10-13: Now answered with a notice (`IgnoreReason::SpaceSwitch`).
* [PARTIAL] Privacy mode (dim the display, hide the picture on the PC). Win: `setPrivacyMode` dropped silently (`dispatch.rs:96`). Mac: `DisplayPrivacyController.swift`, `DisplayPrivacyCurtain.swift`. Buildable as a topmost black window per monitor (cannot dim brightness the same way); capture still sees the screen under it only if the curtain is excluded with `SetWindowDisplayAffinity`. STATUS 2026-10-13: Now answered: turning it on gets a `privacyModeFailed` notice the iPhone words, turning it off says nothing. The curtain itself is not built.
* [PARTIAL] `launchApplication`, `openNewWindow`, `performWindowAction` (close, minimise, zoom). Win: `NotSupportedHere` and `IgnoreReason::WindowAction` (`dispatch.rs:97,114`). Mac: `HostModel+AppLaunching.swift`, `Input/InputInjector+WindowMove.swift`. Buildable (`ShellExecute`, `PostMessage WM_SYSCOMMAND`). STATUS 2026-10-13: Now answered with a notice that lapses after 6 s. The actions are not built.
* [PRESENT] Lock screen command. Win: `crates/peering-platform/src/system.rs:18`, `host/src/runtime/video.rs:65`. Mac: `lockScreen` in `HostModel+Commands.swift`. Note Android never sends it to a Windows host (section 14).

## 7. Audio

* [PRESENT] System audio capture and `audioConfig` and `audioFrame` (Float32 PCM). Win: `MessageKind::AudioConfig` and `AudioFrame` exist (`crates/peering-wire/src/framing.rs:30`) and `AudioCodec` is declared (`crates/peering-wire/src/video/mod.rs:185`), but no host code produces them. Mac: `Video/VideoStreamer+Audio.swift`. Buildable with WASAPI loopback. STATUS 2026-10-13 (second pass): Fixed: WASAPI loopback (`crates/peering-platform/src/audio/sys.rs`), converted to 48 kHz stereo Float32 in 960 sample frames (`crates/peering-core/src/audio`), sent as `audioConfig` and `audioFrame` on the lane the picture takes, listening only while a phone is in the foreground, one waiting frame replaced by a newer as on the Mac. Not run on Windows.

## 8. Input

* [PRESENT] Mouse move over the virtual desktop (absolute, per source), buttons, wheel and horizontal wheel with fractional accumulation. Win: `crates/peering-platform/src/mouse.rs:73,91,111`, `mouse/sys.rs`. Mac: `Input/InputInjector+Events.swift`.
* [PRESENT] Joystick nudges move the real pointer. Win: `crates/peering-platform/src/mouse.rs:174`. Mac: `InputInjector.swift`. Android hides it for Windows hosts (section 14), the iPhone still sends it. STATUS 2026-10-13: The settled position is now reported to the phone, see section 9.
* [PRESENT] Keyboard by scancode with the Mac keycode table and key held tracking. Win: `crates/peering-wire/src/keymap.rs:124`, `crates/peering-platform/src/keyboard.rs:157`. Mac: `InputEncoding.swift`.
* [PRESENT] Modifier mapping: Command is sent as Control, Option as Alt, chords wrap non-modifier keys and do not lift a modifier the user holds. Win: `keymap.rs:132`, `keyboard.rs:176`. Mac: not needed.
* [PRESENT] Text input as UTF-16 `KEYEVENTF_UNICODE`. Win: `keyboard.rs:58`. Mac: `textInput` path.
* [PRESENT] Release of held keys and buttons when a client leaves or hosting stops, and a held input timeout. Win: `crates/peering-core/src/session/held_input.rs:17,40`, `host/src/runtime/control.rs:166,186`. Mac: `HostSession.heldInput`.
* [PARTIAL] Windows key. Win: `WINDOWS_KEY_CODE` 256 maps to the left Windows key (`keymap.rs:4`), but neither phone sends it (they send Mac keycodes), so there is no way to press it. Mac: not applicable.
* [PARTIAL] Shortcuts. Command chords arrive as Control chords (`Cmd+C` works). Mac specific chords (`Cmd+Tab`, `Cmd+Space`, Mission Control) have no mapping; a client cannot choose Alt+Tab or Win+D. Mac: `Modifiers.topRowAction`.
* [MISSING] F-key printed actions (`Modifiers.TOP_ROW_ACTION`, bit 8). Win: defined (`crates/peering-wire/src/command/mod.rs:20`) and read by nothing. Mac: brightness, volume, media keys via `topRowAction`. Buildable as `VK_VOLUME_*`, `VK_MEDIA_*`.
* [N/A] Input into a window on a hidden desktop (`OffDesktopInputGate`). No equivalent concept; see virtual desktops above.
* [N/A] Observe mode. `DispatchContext.observe_mode` is hard coded false (`host/src/runtime/ready.rs:55`); the Mac host app has no observe setting either.

## 9. Pointer, text focus and field state reports to the phone

* [PRESENT] `pointerReport` (0x22) when a hand on the PC moves the pointer. Win: `ClientCapabilities.supports_pointer_report` is parsed (`crates/peering-wire/src/handshake.rs:25`) and the frame kind exists, but nothing sends it. Mac: `Input/PointerWatcher.swift`. Cheap with `GetCursorPos` polling. STATUS 2026-10-13: Fixed: `PointerTracker` (`crates/peering-core/src/pointer.rs`) and `host/src/runtime/pointer_pump.rs` send it for a hand on the mouse and 0.3 s after the last joystick nudge, to clients that declared `supportsPointerReport`. Not run on Windows.
* [PRESENT] `textFocus` (0x1C) and `fieldState` (0x1D). Win: kinds exist (`framing.rs:38`), no producer. Mac: `Input/TextFocusWatcher.swift` (Accessibility). Buildable with UI Automation focus events. STATUS 2026-10-13 (second pass): Fixed: `crates/peering-core/src/focus.rs` carries the Mac watcher rules, `crates/peering-platform/src/focus/sys.rs` reads UI Automation on its own thread, `host/src/runtime/focus_pump.rs` sends the frames to phones that declared the flags. Not run on Windows.

## 10. Clipboard

* [PRESENT] `requestClipboard`, `pushClipboard` text, both directions. Win: dropped before dispatch, `IgnoreReason::Clipboard` (`dispatch.rs:98`), and `requestClipboard` is never answered, so the phone waits. Mac: `ClipboardPasteboard.swift`, `HostSession+Commands.swift:111` (answers an empty text when it cannot read). Buildable with `OpenClipboard` and `CF_UNICODETEXT`. STATUS 2026-10-13: Fixed: `host/src/runtime/clipboard.rs` and `crates/peering-platform/src/clipboard.rs`. A request is always answered, with empty text when there is nothing to give. Not run on Windows.
* [PRESENT] Clipboard image (`pushClipboardImage`, `clipboardContent` with PNG). Win: dropped; `supportsClipboardImages` correctly not set. Mac: `ClipboardPasteboard.swift`. Buildable with `CF_DIB` and a PNG encoder. STATUS 2026-10-13: Fixed: `CF_DIBV5` converted to and from PNG (`clipboard_image.rs`), 8 MiB limit, sent only to a client that declared `supportsClipboardImages`, which the host now sets. Not run on Windows.
* [PRESENT] Reassembly of large control payloads sent as `videoChunk` on the control lane. Win: `peering_wire::chunks::Reassembler` exists (`crates/peering-wire/src/chunks.rs:51`) but the host ignores an inbound chunk (`host/src/runtime/ready.rs:32`). Mac: `HostSession+Commands.swift:38,205` (`handleChunkedPayload`). Only matters once clipboard images or large writes exist. STATUS 2026-10-13: Fixed for the clipboard: an inbound `videoChunk` is reassembled to 12 MiB and run as a command.

## 11. File browsing and transfer

* [PRESENT] List, text and picture preview, ranged read for download preview, drive roots as a virtual tree (`/C:/Users/me`). Win: `crates/peering-core/src/files/browse.rs:36,67`, `files/preview.rs:7`, `host/src/runtime/files.rs:15,41`, `host/src/runtime/terminal.rs:128`. Mac: `Terminal/TerminalSessionManager+FileBrowsing.swift`, `DirectoryListing.swift`.
* [PRESENT] Listing cap 2000 entries, truncation flag, 10 s deadline per request. Win: `files/browse.rs:13`, `host/src/runtime/terminal.rs:28,126`. Mac: `Terminal/FileWork.swift`.
* [PRESENT] Browse scopes per client (`startBrowser`, four per client). Win: `crates/peering-core/src/terminal/manager/browse.rs:9`. Mac: `TerminalSessionManager+FileBrowsing.swift`.
* [PRESENT] Upload (`beginWrite`, `writeChunk`). Win: answered `writeFailure "This PC cannot receive files yet."` (`files/browse.rs:16,49`). Mac: `TerminalSessionManager+FileTransfer.swift`, `+UploadHousekeeping.swift`, `+PendingWrite.swift`. STATUS 2026-10-13: Fixed: `crates/peering-core/src/files/transfer.rs`, run on a writer thread (`host/src/runtime/file_writer.rs`): scratch file beside the destination, moved over it when every byte has arrived, 2 GB cap, 32 KiB pieces, 8 transfers, 16 MiB queue, 90 s idle drop, orphan sweep at start. Not run on Windows.
* [PRESENT] Download of a folder as an archive (`archiveFolder`). Win: `transferFailure` (`files/browse.rs:15,43`). Mac: `TerminalSessionManager+Download.swift`. STATUS 2026-10-13 (second pass): Fixed: `crates/peering-core/src/files/archive.rs` and `zip.rs` write a streaming deflate zip with the 512 MB cap, `host/src/runtime/archive.rs` keeps it under the data folder and deletes it after the last piece. Files that cannot be opened are left out.
* [PRESENT] New file or folder, rename, delete (`changeFile`). Win: `fileOperationFailure` (`files/browse.rs:17,56`). Mac: `TerminalSessionManager+FileChanges.swift`, `RemoteFileName.swift`. STATUS 2026-10-13: Fixed: `crates/peering-core/src/files/changes.rs`. Name rules are the path rules, create and rename never replace, delete goes to the Recycle Bin (`crates/peering-platform/src/recycle.rs`) and refuses the profile, Windows and Program Files folders and anything that holds them. Not run on Windows.
* [PRESENT] Size limits and replacement rules for transfers. Win: none, since nothing is written. Mac: `FileDownloadLimits.swift`, `FileReplacement.swift`. STATUS 2026-10-13: Fixed, see upload.
* [N/A] Protected folder prompt watch. Mac: `Terminal/FolderAccessWatch.swift` (TCC). Windows has no per folder consent prompt.
* [PARTIAL] Agent folder browse. Win: answered on its own thread (`host/src/runtime/agent_browse.rs:47`); no `browseWaiting` for a slow share. Mac: `Agent/Sessions/AgentDirectoryBrowser.swift`.

## 12. Terminals

* [PRESENT] Sessions on ConPTY owned by the creating client, surviving its disconnect, with a retained 512 KiB history replayed on `list`. Win: `crates/peering-platform/src/terminal/conpty.rs:20`, `crates/peering-core/src/terminal/manager.rs:76,100`, `terminal/manager/output.rs:35`. Mac: `Terminal/TerminalSessionManager.swift`, `+Session.swift`.
* [PRESENT] Input, resize, rename, retitle, close, snapshot. Win: `terminal/manager.rs:76`. Mac: same.
* [PRESENT] Shell discovery and choice: PowerShell 7, Windows PowerShell, cmd. Win: `crates/peering-core/src/terminal/shell.rs:30`, `crates/peering-platform/src/terminal/environment.rs:19`. Mac: `Terminal/TerminalSessionManager+Shells.swift`.
* [PRESENT] Attention detection (password or confirmation prompt) and command finished (PowerShell prompt hook). Win: `crates/peering-core/src/terminal/attention.rs:47`, `terminal/finish.rs:35`, `terminal/shell/hook.rs:4`. Mac: `TerminalAttentionDetector.swift`, `TerminalCommandFinishDetector.swift`. cmd.exe has no finish hook.
* [PRESENT] Installed agent probe (`agents` event). Win: `terminal/manager.rs:73`, `host/src/runtime/terminal.rs:68`. Mac: `TerminalSessionManager+AgentProbe.swift`.
* [PARTIAL] Terminal alerts as push. Win: queued for the relay only while the client is not connected (`crates/peering-core/src/terminal/manager/output.rs:48`, `host/src/runtime/terminal.rs:161`); `pushesTerminalAlertsWhileConnected` is not set. Mac: pushes while connected when the phone is backgrounded and sets the flag.
* [PRESENT] Terminal hooks for Claude Code. Win: the hook server, installer and broker are written and tested but compile only with the `terminal-hooks` feature and nothing starts them: no setting, no token, no phone sender, no route from Allow or Deny to `HookBroker::resolve` (`host/src/lib.rs:5`, `host/src/hooks/server.rs`, `crates/peering-core/src/terminal/hooks/broker.rs:57`, `windows/README.md`). Mac: `Terminal/Hooks/*`, `Agent/Sessions/TerminalHook*.swift`. STATUS 2026-10-13: Fixed: a setting and a window switch start the loopback server and install the hooks (`host/src/runtime/hooks.rs`), pushes go through the relay, and an Allow or Deny from the phone reaches `HookBroker::resolve`. The cargo feature is gone. Not run on Windows. Not seen with a phone or the relay.
* [N/A] Native terminal watcher (adopt Terminal.app or iTerm windows via Accessibility). Mac: `Terminal/NativeTerminalWatcher.swift`. Windows equivalent: none planned; sessions are hosted by the app.

## 13. Coding agents

* [PRESENT] Claude Code chat: start, prompt, interrupt, approval allow or deny, close, history replay in chunks, snapshot list. Win: `crates/peering-agent/src/manager.rs:56`, `manager/commands.rs:17,35,55,73,114,150`, `claude_adapter.rs`, `claude_stream.rs`. Mac: `Agent/Adapters/ClaudeCodeAdapter.swift`, `Agent/Sessions/AgentSessionManager.swift`.
* [PRESENT] Pause a chat and pick it up again on the next prompt. Win: `manager/commands.rs:126`. Mac: `AgentSessionManager+Lifecycle.swift`. Not advertised, see section 14.
* [PRESENT] Model change and permission mode change. Win: `manager/commands.rs:83,97`. Mac: `PerTurnAdapter.swift`, `ClaudeCodeAdapter.swift`. Not advertised, see section 14.
* [PRESENT] Usage report after each turn. Win: `crates/peering-agent/src/manager/session.rs:99`. Mac: `AgentUsage`. Not advertised and not gated, see section 14.
* [PARTIAL] Agent list. Win: Claude only (`manager.rs:23,32`), `start` for another id fails "not supported on this host yet" (`manager/commands.rs:18`). Mac: Claude Code, Codex, OpenCode (`Agent/Adapters/AgentCatalogue.swift`, `CodexAdapter.swift`, `OpenCodeAdapter.swift`).
* [MISSING] Changes view (`changes`), `commit`, `push`. Win: answered `failed "This is not supported on this host yet."` (`manager.rs:67`). Mac: `Agent/Sessions/AgentChangesReader.swift`, `AgentGitActions.swift`, `AgentGitRunner.swift`. Buildable with git for Windows.
* [MISSING] Resumable conversations (`listResumable`, `resume`) and `supportsAgentSessionImport`. Win: `manager.rs:70`. Mac: `Agent/Sessions/ClaudeSessionLibrary.swift`, `AgentSessionManager+Import.swift`, `AgentResumableSession.swift`. Reads `%USERPROFILE%\.claude\projects`.
* [MISSING] Web preview proxy (`previewRequest`, `previewEvent`). Win: the frame kind is routed to `ReadyOutcome::Unhandled(_)` and dropped with no reply (`host/src/runtime/ready.rs:32`), so a phone request waits for its own timeout. Mac: `Agent/Preview/PreviewProxyService.swift`, `PreviewTransfer.swift`.
* [MISSING] Back pressure hold of agent events while the phone is backgrounded. Win: events go to the newest session of the client at once (`host/src/runtime/agent_pump.rs:26`). Mac: `Network/ClientOutputGate.swift`, `AgentSessionManager+BackPressure.swift`.
* [PRESENT] Agent approval and turn finished pushes through the relay. Win: only terminal alerts are queued (`host/src/runtime/terminal.rs:166`; `approval_id` and `session_id` are always `None`). Mac: `Agent/Sessions/AgentNotificationWords+Localized.swift`, `Terminal/PushTokenStore.swift`. STATUS 2026-10-13: Claude Code hook approvals now push through the relay (see section 12); chat approvals and turn finished do not. STATUS 2026-10-13 (second pass): Fixed: `crates/peering-agent/src/push.rs` plans the pushes with the Mac rules and `host/src/runtime/agent_pump.rs` queues them for the relay. Words are English only. `notifyActivity` is still not sent.
* [MISSING] Agent analytics events. Win: none. Mac: `Agent/Analytics/*`.
* [PRESENT] One agent manager per client, kept for the life of the host, so a reconnecting phone finds its chats; they do not survive a host restart. Win: `crates/peering-agent/src/manager/clients.rs:10`. Mac: same, plus resume from disk (below).

## 14. Handshake capability flags

`ServerHello` flags the Mac sets and what the Windows host does. "Set" means the value written into the hello.

* [PRESENT] `supportsVideoPause`: set true (`crates/peering-core/src/session/handshake.rs:195`), handled (`coordinator.rs:163`).
* [PRESENT] `supportsClientState`: set true (`handshake.rs:196`), handled (`host/src/runtime/ready.rs:62`).
* [PRESENT] `supportsAgentList` and `supportsAgentChat` and `agentChatAgents`: set only while `claude` is found (`host/src/runtime/connection/actions.rs:66`, `crates/peering-agent/src/availability.rs:33`). Honest.
* [PRESENT] `supportsFileBrowser`: set true always (`actions.rs:71`); listing and reading work, every write answers a failure event. Mac: true with writes. Honest enough because the failures are explicit, but a phone shows the upload and rename actions. STATUS 2026-10-13: Now honest: listing, reading, upload, create, rename and delete work; a folder archive still answers `transferFailure`.
* [PRESENT] `supportsAgentModelPicker`: not set though `setModel` works (`manager/commands.rs:83`). The phone hides the picker. Fix: set it. STATUS 2026-10-13: Fixed: set with the other agent flags while the CLI is found.
* [PRESENT] `supportsAgentPermissionModes`: not set though `setPermissionMode` works (`manager/commands.rs:97`), and the client's own flag is never recorded (`host/src/runtime/connection.rs:196` keeps only `supportsAgentChat`). Fix: set it and record the client flag. STATUS 2026-10-13: Fixed: set, and the client flag is recorded per connection and per session.
* [PRESENT] `supportsAgentUsage`: not set though usage is collected (`manager/session.rs:99`). Same fix. STATUS 2026-10-13: Fixed: set.
* [PRESENT] `supportsAgentPause`: not set though `pause` works (`manager/commands.rs:126`). Same fix. STATUS 2026-10-13: Fixed: set.
* [MISSING] `supportsAgentSessionImport`: correctly not set (no resumable list).
* [PARTIAL] `supportsClipboardImages`, `supportsMosaic`, `supportsSourceThumbnails`, `supportsDeviceOrientation`, `supportsVirtualDisplayManagement`: correctly not set because the features are missing. STATUS 2026-10-13: `supportsClipboardImages` is now set; the rest stay unset because the features are missing.
* [PARTIAL] `pushesTerminalAlertsWhileConnected`: correctly not set (alerts push only while disconnected).
* [MISSING] `supportsLiveActivityPush`: not in the Windows `ServerCapabilities` struct (`crates/peering-wire/src/handshake.rs:33`); correctly absent, see section 16.
* [PRESENT] `supportsLockScreen`: the Windows host sets true (`actions.rs:72`) but the field is not in the Swift `ServerHello` and not read by Android (`HostCapability.kt:47` uses `hostPlatform`), and `docs/protocol.md:247` says no such flag exists. Emitted, read by nobody. STATUS 2026-10-13: Fixed: the field is removed from the Windows hello; no client reads it and the spec has no such flag.
* [PRESENT] `hostPlatform: "windows"` (`handshake.rs:200`). Read by Android; ignored by the iPhone.
* [PRESENT] `ClientHello` flags parsed: `supportsClipboardImages`, `supportsTextFocus`, `supportsFieldState`, `supportsPointerReport`, `supportsAgentChat`, `supportsAgentPermissionModes`, `supportsAgentUsage` (`crates/peering-wire/src/handshake.rs:25`). Only `supportsAgentChat` is acted on; the others have no consumer. STATUS 2026-10-13: All seven flags are now recorded per connection and per session (`Connection::client_flags`, `SessionSlot::client_flags`) and acted on.
* [PRESENT] `clientPlatform`, `videoCodecs`, `resumeSource`, `lostPairing` parsed and stored (`crates/peering-wire/src/handshake.rs:70,73,76`). `resumeSource` is honoured only for a paired client (`handshake.rs:205`); `videoCodecs` is stored and unused.
* [MISSING] `ClientHello.sessionRef` analytics tag: unknown key, ignored. Harmless.

## 15. Messages and commands the phone can send

`RemoteCommand` cases (`docs/protocol.md` section 8, `crates/peering-wire/src/command/mod.rs:100`). "Dropped" means no reply of any kind.

* [PRESENT] `mouseMove`, `mouseDown`, `mouseUp`, `scroll`, `keyDown`, `keyUp`, `textInput`, `joystickMove`: applied (`dispatch.rs:60`).
* [PRESENT] `setCaptureSource` for a display: applied; an unknown display gives `error sourceUnavailable` (`host/src/runtime/ready.rs:18`).
* [PARTIAL] `setCaptureSource` for a window or application: answered `error sourceUnavailable` (`coordinator/source.rs:56`). For a mosaic: dropped silently (`dispatch.rs:101`). STATUS 2026-10-13: Now a `displayDisconnected` notice, which the iPhone words and which lapses, instead of an `error` frame that ends an iPhone session. A mosaic gets a notice too.
* [PARTIAL] `setStreamQuality`: bitrate applied; `fps` applied but snapped to 15, 30 or 60 and changes the host wide rate rather than a per client cap (`host/src/runtime/video.rs:52`, `settings.rs:93`).
* [PRESENT] `setVideoEnabled`: applied.
* [PRESENT] `lockScreen`: applied (`video.rs:65`); Android never sends it to a Windows host.
* [PARTIAL] `switchSpace`, `switchToSpace`, `refreshSpacePreviews`: dropped (`dispatch.rs:92`). STATUS 2026-10-13: Now answered with a notice.
* [PARTIAL] `launchApplication`, `openNewWindow`: dropped (`dispatch.rs:114`). STATUS 2026-10-13: Now answered with a notice.
* [PARTIAL] `performWindowAction`: dropped (`dispatch.rs:97`). STATUS 2026-10-13: Now answered with a notice.
* [PARTIAL] `setPrivacyMode`: dropped (`dispatch.rs:96`). STATUS 2026-10-13: Now answered with a notice.
* [MISSING] `refreshSourceThumbnails`, `watchSourceThumbnails`: dropped (`dispatch.rs:114`).
* [PRESENT] `requestClipboard`, `pushClipboard`, `pushClipboardImage`: dropped (`dispatch.rs:98`). STATUS 2026-10-13: Fixed, see section 10.
* [MISSING] `reportDeviceOrientation`: dropped (`dispatch.rs:114`). Harmless: only sent when the host declares support.
* [MISSING] `addVirtualDisplay`, `removeVirtualDisplay`, `renameVirtualDisplay`: dropped (`dispatch.rs:93`). Only sent when the host declares support.

Frame kinds a phone can send:

* [PRESENT] `connectionRole`, `clientHello`, `pairCommit`, `pairReveal`, `pairConfirm`, `command`, `ping`: handled by the core (`crates/peering-core/src/session/handshake.rs:106`, `dispatch.rs:70`).
* [PRESENT] `terminalRequest`, `agentRequest`, `videoKeyRequest`, `videoTransport`, `clientState`: handled (`host/src/runtime/ready.rs:27`).
* [PRESENT] `directProbe` over UDP: handled (`host/src/runtime/relay_lane.rs:137`).
* [PARTIAL] `previewRequest` (0x20): dropped silently (`ready.rs:32`). Not gated by any flag on the phone. STATUS 2026-10-13: Now answered with a `previewEvent` `failure` (`notAllowed`) carrying the request id, so the page stops waiting. The proxy itself is not built.
* [PRESENT] `videoChunk` (0x17) on the control lane: dropped (`ready.rs:32`); see section 10. STATUS 2026-10-13: Fixed for clipboard commands, see section 10.
* [PRESENT] `activityToken` (0x24): the kind is missing from `MessageKind` (`crates/peering-wire/src/framing.rs:83`), so a phone that sent it would hit "unknown kind" and the host would close the connection. Safe only because the phone sends it solely to a host that declared `supportsLiveActivityPush`, which this host never does. The spec says an unimplemented kind must be ignored; fix by adding the kind and ignoring it. STATUS 2026-10-13: Fixed: the kind is in `MessageKind` and the frame is read and ignored.
* [N/A] `setCaptureSource` frame (0x08): unused by the protocol itself.

## 16. Live Activity, notices and presence

* [MISSING] Live Activity pushes (`activityToken` in, `notifyActivity` out, cards for session and agent chat). Win: no handler, no planner (`crates/peering-wire/src/relay_messages/mod.rs:97` only). Mac: `LiveActivity/HostLiveActivityPublisher.swift`, `LiveActivityPushBuilder.swift`, `RelayActivityPush.swift`. iPhone only.
* [PRESENT] `notice` frames with `code`: secure desktop or lock, `captureNoFrames`, `captureRecovering`, standing notice resent on join. Win: `host/src/runtime/video.rs:91,146`, `crates/peering-core/src/notice.rs:29`, `host/src/runtime/connection/register.rs:60`. Mac: `lockedDisplayID` notices.
* [PRESENT] `error hostStopped` when hosting is switched off. Win: `host/src/runtime/control.rs:182`. Mac: same.
* [PRESENT] Wake-on-LAN addresses in the hello. Win: `mac_addresses` is always empty (`host/src/runtime/profile.rs:16,28`). Mac: `NetworkInterfaceInfo.hardwareMACAddresses()`. Buildable with `GetAdaptersAddresses`. STATUS 2026-10-13: Fixed: `GetAdaptersAddresses` for Ethernet and Wi-Fi adapters (`crates/peering-platform/src/addresses.rs`), in the hello of a paired client. Not run on Windows.

## 17. Power, lock, login, update

* [PRESENT] Keep awake while a phone is connected. Win: no `SetThreadExecutionState` or power request anywhere in the workspace. A PC that sleeps drops the session. Mac: `SleepPrevention/HostModel+SleepPrevention.swift`, `KeepAwakeRow.swift`. STATUS 2026-10-13: Fixed: `SetThreadExecutionState` through `SystemActions::set_keep_awake`, on while hosting with a session and released on disconnect or when hosting stops. Not run on Windows.
* [MISSING] Keep awake schedule, wake schedule, lid-close sleep control. Mac: `KeepAwakeScheduleRow.swift`, `WakeScheduleRow.swift` (pmset), `LidCloseSleepControl.swift`. Windows equivalents: `powercfg`, scheduled task with wake timer.
* [PRESENT] Lock screen detection and a phone side notice. Win: `crates/peering-platform/src/session_state.rs:43`, `session_state/sys.rs:54`. Mac: lock notice.
* [PRESENT] Start at login through the HKCU Run key. Win: `host/src/autostart.rs:56,101`, `host/src/ui/settings.rs`, installer task `peering-host.iss`. Mac: `LaunchAtLogin.swift`. Default in `HostSettings` is true but the installer task is unchecked.
* [PARTIAL] Auto update. Win: nothing checks for or installs a newer build. Mac: `Updater.swift` (Sparkle against the relay appcast). Windows equivalents: a check against the relay appcast with a download link, or MSIX with App Installer, or `winget`. STATUS 2026-10-13 (second pass): A notice, not an updater: `crates/peering-core/src/update.rs` and `host/src/runtime/update.rs` read the repository's GitHub releases once a day and the window offers the release page. Nothing is downloaded or installed, and the installer is still unsigned.
* [MISSING] Code signing. Win: unsigned installer, SmartScreen warning (`windows/README.md`). Mac: notarised DMG.
* [PRESENT] Installer. Win: `windows/installer/peering-host.iss`, `installer/build.ps1`, `.github/workflows/windows-release.yml`. Per user, no elevation. Not yet run (`windows/README.md`).
* [N/A] Permission onboarding (Accessibility, Screen Recording). Mac: `PermissionOnboardingView.swift`, `Permissions.swift`. Windows needs none for these; the equivalent is the firewall step.

## 18. Host UI

* [PRESENT] Tray icon with status and menu: start or stop hosting, pairing code, devices, settings, quit. Win: `host/src/ui/tray.rs`, `ui/model.rs:224`. Mac: `MenuBar/MenuBarController.swift`, `HostMenuBarContent*.swift`.
* [PRESENT] Window with the pairing QR and code, approvals, paired phones, problems list. Win: `host/src/ui/app.rs:102`, `ui/pairing.rs`. Mac: `HostStatusView+Connect.swift`, `+Devices.swift`.
* [PARTIAL] Settings. Win: start at login, fix firewall, frame rate (not saved) (`host/src/ui/settings_view.rs`, `settings.rs`). `HostSettings` in `crates/peering-core/src/settings.rs:7` (port, relay, device name, start at login) is written but never loaded or saved by the host. Mac: launch at login, keep awake rows, preview, hooks, analytics, pointer, resolution, frame rate, codec, port. STATUS 2026-10-13: Port, relay, device name, frame rate, start at login and hooks are loaded from and saved to `settings.txt`; the window shows start at login, relay, hooks, firewall and frame rate. The port and device name have no control in the window.
* [PARTIAL] Activity log and session history. Win: `diagnostics::log` writes to stderr, which a windowed build does not have (`host/src/runtime/diagnostics.rs:7`); only a problems list shows. Mac: `HostLogEntry.swift`, `HostSessionRecord.swift`, `HostStatusView+Devices.swift:230,328`. STATUS 2026-10-13 (second pass): A rotating file log now exists (`host/src/logfile.rs`, `%LOCALAPPDATA%\Peering Host\logs`, with an Open log folder button). There is still no activity list or session history in the window.
* [MISSING] Live preview of the PC screen in the window. Mac: `previewRow`, `HostStatusView+Session.swift`.
* [MISSING] Resource figures (CPU, memory, network) in the window. Mac: `HostResourceSampler.swift`.
* [MISSING] About, version and first-connection onboarding. Mac: `HostStatusView+About.swift`, `FirstConnectionOnboardingView.swift`, `AwaySwitchesOnboardingView.swift`.
* [N/A] Desktop widget. Mac: `HostModel+Widget.swift`. Windows equivalent: none planned.

## 19. Analytics, crash reporting, localisation

* [MISSING] Anonymous usage analytics with an off switch. Mac: `Analytics.swift`, `Telemetry/*`, `PostHogConfiguration.swift`. Win: none.
* [MISSING] Crash reporting. Win: none; the pumps use `catch_unwind` for recovery only (`host/src/runtime/video_pass.rs:6`). Mac: PostHog error tracking (`PostHogLog.swift`).
* [MISSING] Localised host UI. Win: every string is an English constant (`host/src/strings.rs`). Mac: `Localizable.xcstrings`, `InfoPlist.xcstrings`.
* [MISSING] Dark or branded theme. Win: default egui styling (`host/src/ui/app.rs:107`). Mac: `Theme.swift` (see `wiki/DESIGN.md`).

## 20. Resilience

* [PRESENT] Capture recovery ladder, device lost handling, stall probe and rebuild, and a hung pass abandoned. Win: `crates/peering-core/src/video/recovery.rs`, `supervision.rs`, `host/src/runtime/video_handle.rs:93`, `supervise.rs`. Mac: `CaptureRecovery.swift`, `VideoCoordinator+Recovery.swift`.
* [PRESENT] Pumps held off with backoff after a panic; a pump that ends stops the host and says why. Win: `host/src/runtime/video_pass.rs:231`, `serve.rs:76`. Mac: model level supervision.
* [PRESENT] Relay reconnect ladder, frame deadline, liveness limits (60 s, 180 s in the background). Win: `registration.rs:193`, `crates/peering-core/src/session/liveness.rs`. Mac: `HostServer.swift`.
* [PRESENT] Bounded outbound queues that drop video first and end an overflowing connection. Win: `crates/peering-core/src/outbound.rs:27`, `host/src/runtime/connection.rs:101`. Mac: `ClientOutputGate.swift`.
* [PARTIAL] Network change and sleep or wake. Win: no observer; relay reconnects only on a socket error. Mac: `Network/NetworkChangeObserver.swift`.
* [PARTIAL] Unattended run. Win: nothing prevents sleep and the process has no watchdog beyond its own threads. Mac: keep awake plus the system launch agent. STATUS 2026-10-13: The PC no longer sleeps while a phone is connected; there is still no watchdog beyond the host's own threads.

## Advertised but not handled

Nothing is advertised that the host cannot do at all. These are the cases where the claim and the behaviour disagree:

1. `supportsFileBrowser` true while `beginWrite`, `writeChunk`, `archiveFolder` and `changeFile` always fail (`host/src/runtime/connection/actions.rs:71`, `crates/peering-core/src/files/browse.rs:15-17`). The failures are explicit events, so the phone shows an error rather than hanging.
2. `supportsLockScreen` true (`actions.rs:72`) is a field no client reads and `docs/protocol.md:247` denies exists. Android additionally blocks `lockScreen` for any non-Mac host (`HostCapability.kt:47`), so the working Windows lock is unreachable from Android.
3. `permissionModeChanged` and `usageChanged` agent events are sent to every chat client (`crates/peering-agent/src/manager/session.rs:99`) although the Mac withholds them from clients that did not declare `supportsAgentPermissionModes` or `supportsAgentUsage` (`HostSession+Commands.swift:176-177`), because an unknown enum case ends an old client's session. The host also never records those client flags (`host/src/runtime/connection.rs:196`). Current phones declare both; a shipped older build would not.
4. Commands the phone sends with no flag guard that the host drops without any reply: `requestClipboard` (the phone waits), `setPrivacyMode`, `switchSpace`, `launchApplication`, `performWindowAction`, `openNewWindow`, `setCaptureSource` mosaic, and `previewRequest`. The iPhone has no `hostPlatform` gating that I could find, so it should still show the controls on a Windows host (not tried on a device); Android hides them.
5. The hello does not advertise what works: `supportsAgentModelPicker`, `supportsAgentPermissionModes`, `supportsAgentUsage` and `supportsAgentPause` are unset though the manager implements all four, so the phone hides finished features.
6. `activityToken` (0x24) is unknown to `MessageKind`, so a stray one closes the connection instead of being ignored as `docs/protocol.md` section 3 requires.
7. `HostSettings` (port, relay on or off, device name, frame rate, start at login) is written, tested and documented as the settings model but is not loaded or saved by the host.

## Worth building next

Ranked by impact against effort (XS under a day, S a day or two, M about a week, L several weeks).

1. Gate `permissionModeChanged` and `usageChanged` on the client's declared flags, record those flags in `Connection`, and ignore the unknown `activityToken` kind. XS. Closes the only item that can end a session on an older phone.
2. Set `supportsAgentModelPicker`, `supportsAgentPermissionModes`, `supportsAgentUsage` and `supportsAgentPause` in `decorate`. XS. Four finished features become visible.
3. Keep the PC awake while a phone is connected (`SetThreadExecutionState`, system and display required). XS. A sleeping PC is the most common reason a remote session dies.
4. Text clipboard in both directions and an answer to every `requestClipboard` (empty text when unreadable, as the Mac does). S. The phone currently waits on a reply that never comes.
5. Load and save `HostSettings` (frame rate, relay on or off, device name, port) and wire the relay toggle. S. The model and tests exist.
6. Show the pointer: either send `pointerReport` for `supportsPointerReport` clients or composite the cursor into the frame. M. Without it the phone shows no cursor on a Windows PC (to be confirmed on a device).
7. Wake-on-LAN addresses in the hello (`GetAdaptersAddresses`). XS. Lets a phone wake a sleeping PC on the LAN.
8. File upload, download of a folder as an archive, new, rename and delete, with the Mac's size limits. M. Turns the already advertised `supportsFileBrowser` into the whole feature.
9. Wire the Claude Code terminal hooks (setting, token, phone sender, route Allow and Deny to `HookBroker::resolve`) and drop the cargo feature. M. The code and tests exist; it is the integration that is missing.
10. System audio through WASAPI loopback as Float32 PCM `audioConfig` and `audioFrame`. M to L. The wire types exist; no producer.
11. Window and application capture sources plus the full catalogue (windows, applications, icons) with Windows.Graphics.Capture. L. The largest gap in the picker, and it unlocks thumbnails and mosaic.
12. `textFocus` and `fieldState` from UI Automation so the phone raises its keyboard. M. High for phone typing comfort.
13. Agent changes, commit and push, and resumable Claude conversations from `%USERPROFILE%\.claude\projects`. M. Brings chat to parity for the one agent supported.
14. Update check against the relay appcast, then code signing. M plus certificate cost. Removes the SmartScreen warning and the manual reinstall.
15. A rolling log file under `%LOCALAPPDATA%` and an activity list in the window. S. Today a failure in a windowed build leaves no trace, which also blocks diagnosing everything above on real hardware.

Not on the list on purpose: virtual displays (needs an indirect display driver), Spaces (undocumented API), HEVC (bandwidth only), localisation and analytics (policy first), Live Activity (iPhone only, needs presence work).

## Status after the fixes (2026-10-13)

Written from the code and its tests (`cargo test --workspace` and clippy on macOS, `cargo check --target x86_64-pc-windows-msvc -p peering-platform`).
Nothing below has run on Windows: the `host` crate cannot be checked for the Windows target from a Mac because `ring` needs a C toolchain
for it, so the window code (`host/src/ui/app.rs`, `settings_view.rs`) and the adapters file (`host/src/runtime/services/windows.rs`) are
written by hand against the APIs and unchecked.

"Advertised but not handled", by number:

1. `supportsFileBrowser`: now true to what works (list, read, upload, create, rename, delete). A folder archive still answers `transferFailure`.
2. `supportsLockScreen`: removed from the Windows hello.
3. `permissionModeChanged` and `usageChanged`: sent only to a client that declared the matching flag and `supportsAgentChat` (`host/src/runtime/agent_gate.rs`), for chat replies and for the output pump alike. The flags are recorded per connection and per session.
4. Dropped commands: `requestClipboard` is answered (empty text when there is nothing), `previewRequest` gets a `failure` event with its id, and `setPrivacyMode`, `switchSpace`, `launchApplication`, `openNewWindow`, `performWindowAction`, a mosaic source and a source that cannot be captured each get a notice that lapses after 6 s. An `error` frame is never used for these: it ends an iPhone session (`ClientSession+Commands.swift`, `.error` calls `fail`). The old `error sourceUnavailable` for an unusable capture source was changed the same way.
5. The four agent flags are set while the CLI is found.
6. `activityToken` (0x24) is a known kind and is ignored.
7. `HostSettings` is loaded at start and saved on change.

"Worth building next", by number: 1 to 9 done (9 as setting, token, relay push and the Allow or Deny route; chat approvals through the relay are not).
10 (audio) not done: WASAPI loopback, an encoder and a new stream; a large subsystem with nothing to test it against here.
11 (window and application sources) not done, see section 6.
12 (`textFocus`, `fieldState`) not done: needs UI Automation focus events.
13 (agent changes, commit, push, resumable conversations) not done.
14 (update check, signing) not done.
15 (rolling log file) not done.

Still open from this audit: the `hostPresence` and `notifyActivity` relay messages, HEVC, a capture resolution setting, F-key actions,
network change and wake observers, the activity list, analytics, localisation.

## Status after the second pass (2026-10-13)

Written from the code and its tests (`cargo test --locked --workspace` and `cargo clippy --locked --workspace --all-targets` on macOS, and
`cargo check` and `cargo clippy` of `peering-platform` and `peering-host` for `x86_64-pc-windows-msvc` with the stub C compiler and archiver of
`windows/README.md`). Every Windows-only call below compiles and none has run on Windows.

"Worth building next", by number:

* 6 (the pointer): done both ways. `pointerReport` as before, and the pointer is drawn into the picture.
* 8 (folder download): done; the folder is zipped and read in pieces, with the Mac's 512 MB cap.
* 10 (audio): done, see section 7.
* 11 (window and application sources): windows done with a catalogue that lists only what the system accepts for capture; applications, icons,
  thumbnails and a mosaic are not done (Windows.Graphics.Capture has no several-window source).
* 12 (`textFocus`, `fieldState`): done.
* 13 (agent changes, commit, push, resumable conversations): not done.
* 14 (update check): a notice with a link, no installer and no signing.
* 15 (rolling log): done; no activity list in the window.
* Chat approvals and finished turns through the relay: done. Live Activity (`activityToken` in, `notifyActivity` out, `hostPresence`): not done.
  It is iPhone only, needs the card state builders and a presence registry, and cannot be tried without an iPhone.

Capability flags: nothing new is advertised, because audio, text focus, field state and the pointer have no host side flag (the client declares
what it wants), `supportsMosaic` and `supportsSourceThumbnails` stay unset because neither works, and `supportsLiveActivityPush` stays unset.

Not done, with the reason: privacy curtain (a topmost window per monitor that the capture does not see needs `SetWindowDisplayAffinity`
and a design for input that the audit did not settle), Spaces (virtual desktops have no documented API), virtual displays (an indirect display
driver), application sources and thumbnails (above), code signing (a certificate), HEVC (bandwidth only), keep awake and wake schedules
(`powercfg` and scheduled tasks need elevation).
