# Peering Host for Windows

The Windows host is a Rust workspace. The plan is `docs/plans/android-and-windows.md`, and the wire protocol is
`docs/protocol.md`. The host runs on this PC, accepts paired phones on the local network (TCP 51515) and through the
relay, and shows its pairing code in a tray window.

The Mac can check the logic and the Windows platform crate, but not the host binary: the host depends on `ring`, which
does not cross compile from macOS. The Windows-only parts are compiled and run on Windows only.

## Build from source

1. Install Rust with [rustup](https://rustup.rs). The workspace pins its toolchain in `rust-toolchain.toml`, and rustup
   installs that version on first use.
2. Install Visual Studio Build Tools with the **Desktop development with C++** workload and a Windows SDK. Rust links with
   the MSVC toolchain, which needs both.
3. From the `windows` folder, build the release binary:

   ```
   cargo build --release -p peering-host
   ```

   The executable is `windows\target\release\peering-host.exe`.

4. Run the tests:

   ```
   cargo test --workspace
   ```

The tests use in-memory streams and fakes, so they need no network, no device and no administrator rights.

To check only the Windows platform crate from another machine (this needs the `x86_64-pc-windows-msvc` target installed):

```
cargo check -p peering-platform --target x86_64-pc-windows-msvc
```

## Running without a signed installer

Releases of Peering Host are not code signed. Windows Defender SmartScreen therefore shows a warning the first time the
program runs:

> Windows protected your PC. Microsoft Defender SmartScreen prevented an unrecognized app from starting.

To run it anyway, select **More info**, then **Run anyway**. The warning appears because the publisher is unknown, not
because the program was found to be harmful. Building from source produces the same unsigned executable, and the same
warning, unless you sign it yourself.

## Installer

`installer\peering-host.iss` is an [Inno Setup](https://jrsoftware.org/isinfo.php) 6 script. It installs for the current
user only, with no administrator rights, into `%LOCALAPPDATA%\Programs\Peering Host`. It adds a Start menu shortcut, an
uninstaller, and an optional task to start the host when you sign in. The installer is unsigned, so the SmartScreen
warning above applies to it too.

To build the installer, install Inno Setup 6, then from the `windows` folder run:

```
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

The script builds the release executable if it is missing and writes `windows\dist\PeeringHostSetup.exe`. The `dist`
folder is ignored by git.

Pushing a `windows-v*` tag runs `.github/workflows/windows-release.yml`, with no paths filter, which calls the build and
tests of `windows.yml` and attaches the installer to a release. The installer's version is the tag without `windows-v`.

## Layout

- `crates/peering-wire`, `crates/peering-core`, `crates/peering-agent`, `crates/peering-net`: protocol, host logic,
  agent chat and identity. None of them depends on a Windows API.
- `crates/peering-platform`: the Windows adapters (desktop duplication, Media Foundation, SendInput, DPAPI). Its pure
  parts are tested on any OS.
- `host`: the process. The runtime serves clients, `ui` holds the tray and pairing window, and `autostart` and
  `firewall` hold the start-at-login and firewall helpers.

## Settings

`%LOCALAPPDATA%\Peering Host\settings.txt` holds `key=value` lines: `port`, `frameRate` (15, 30 or 60), `startAtLogin`,
`relayEnabled`, `deviceName`, `terminalHooks`, `cursorInPicture` (the pointer is drawn into the picture, on by default) and
`checkForUpdates` (on by default). It is read at start and rewritten whole (through a file beside it that is
renamed over it) whenever the window changes a setting. A key that is missing or out of range takes its default, and a file
that cannot be read starts the host on the defaults and says so in the window. The window has controls for start at login,
the relay, the hooks, the update notice, the firewall rule and the frame rate, and a button that opens the log folder. The port, the
device name and `cursorInPicture` are changed in the file, and take effect at the next start. The relay switch takes effect at once. `startAtLogin` follows the Run entry, which stays the truth.

## What a phone gets besides the picture

- Clipboard, both directions: Unicode text, and pictures as `CF_DIBV5` converted to PNG (8 MiB). Anything larger than one
  frame travels as 16 KiB `videoChunk` pieces, up to 12 MiB. A request is always answered, with empty text when the clipboard
  is empty, busy or holds something the phone cannot take.
- The PC stays awake (`SetThreadExecutionState`, system and display) while hosting with at least one phone connected.
- Paired phones are given the hardware addresses of the Ethernet and Wi-Fi adapters, for Wake-on-LAN.
- `pointerReport` when a hand moves the mouse and 0.3 s after the last joystick nudge, for phones that declared it.
- Files: upload, new file or folder, rename and delete. An upload goes to `.name.peering-<id>.part` beside the destination and is
  moved over it when every byte has arrived (2 GB at most, 32 KiB pieces, 8 transfers at once, a transfer silent for 90 s is
  dropped). Names follow the same rules as paths from the phone, so a name cannot leave its folder or open a device. Create and
  rename never replace a name that is taken. Delete goes to the Recycle Bin, only from the PC's own drives, and refuses the user
  profile, the Windows folder, Program Files, ProgramData and anything that holds them. A folder is zipped to
  `%LOCALAPPDATA%\Peering Host\archives\<id>\<Folder>.zip` (deflate, 512 MB at most, 65535 entries at most, links not followed, files
  that cannot be opened left out), announced with `archiveReady`, read by the phone in 32 KiB pieces and deleted after the last. Two
  at a time; a zip nobody finished reading goes after an hour, and the folder is emptied at start.
- Sound: what the PC plays (WASAPI loopback on the default playback device, which is followed when it changes) is sent as
  `audioConfig` and `audioFrame`, 48 kHz stereo Float32, while a phone in the foreground is connected. Silence sends nothing.
- The pointer is drawn into the picture (the duplication's shape and position, composited on the GPU copy of the frame; a pointer-only
  change makes a new frame). A window capture has the system draw it. `pointerReport` still goes to the phones that declared it.
- `textFocus` and `fieldState` go to phones that declared `supportsTextFocus` and `supportsFieldState`, read with UI Automation on a
  thread of its own every 300 ms while such a phone is connected, and again 150 ms after a phone's click.
- Windows: the picker lists the top-level windows the system will capture (Windows.Graphics.Capture), each checked when listed.
  Choosing one streams that window and maps the phone's pointer into it; closing it returns the picture to the primary display.
  Applications (several windows of one program) and icons are not offered. Thumbnails are: a screenshot of each window and display (`PrintWindow`, `BitBlt`), shrunk to 240 px across and sent in the catalogue while a phone has its picker open.
- Pushes through the relay: an agent chat's approval request, and a finished turn when the phone is not in the foreground, in
  addition to the Claude Code hooks. They need a push token the phone registered and a relay connection.
- A log: `%LOCALAPPDATA%\Peering Host\logs\peering-host.log`, 1 MiB each, three older files kept, panics included.
- A newer build: once a day (the first look a minute after start) the host reads the repository's releases from `api.github.com`,
  takes the newest `windows-v*` that is not a draft or pre-release, and the window shows "Version x is available" with a button
  to its release page. Nothing is downloaded or installed. The running version is the crate's, or the release tag's when the
  build is made with `PEERING_RELEASE_TAG` (the `windows.yml` release build sets it), so a tagged build knows its own number.
- What the host will not do is answered with a notice that lapses after 6 s (desktops, launching apps, window actions, privacy
  mode, a mosaic, a source it cannot capture) and a web preview request gets a `failure` event. An `error` frame is never used
  for this, because it ends an iPhone session.

Not built: application capture (WGC captures one window or one screen, not the windows of a program together), source icons, the web preview proxy, Live Activity pushes (`notifyActivity`), a real privacy curtain, Spaces, a mosaic, HEVC, the keep
awake and wake schedules, and signing. The Windows-only code behind this section (WASAPI, UI Automation, Windows.Graphics.Capture, the
duplication's pointer, the HTTPS request) is written against the `windows` crate 0.58 and type-checked for the Windows target;
none of it has run on a Windows machine.

## Claude Code terminal hooks

With the setting on (the window's "Send Claude Code approvals to my phone"), the host listens on a loopback port with a token it
mints on every start, writes `peering-hook.cmd` beside its settings, and adds `PermissionRequest` and `Notification` hooks to
`%USERPROFILE%\.claude\settings.json` (leaving every other key alone, keeping one copy of the original as
`settings.json.peering-backup`, and refusing a file it does not understand). A permission request becomes a push through the
relay and is held until the phone answers; an Allow or Deny arrives as an ordinary `agentRequest` approval and goes to
`HookBroker::resolve` before any chat is asked. With no answer in ten minutes, or no phone registered for pushes, Claude Code
shows its own prompt. Turning the setting off removes the hooks and the script. If the hooks cannot be installed the setting
turns itself off and the window says why. The chain is tested over a real loopback socket with a scripted phone. It has not been
seen with a real phone, the relay or Claude Code.

## Status

The Windows-only code has not yet been run on a Windows machine. The build steps and the installer script are written
but have not been run either. Until a real run has been recorded, treat them as untested.

## What is verified

Checked on macOS, with the commands in this file:

- `cargo test --workspace` passes. It covers the protocol, the core state machines, the platform crate's pure parts
  (the NV12 layout, the encoder settings and candidate order, frame timing, the link between capture and encoder, the
  duplication back-off), the host's runtime over fakes and loopback UDP sockets (the relayed video lane, the pings and
  pongs, the fallback to the control connection and back, the direct probe), the lock and frame rate requests, and the
  settings model that the window draws.
- The pure parts of the second pass (the audio conversion and its routing and drop rule, the pointer shapes and blending, the focus
  rules, window selection, the catalogue with windows, falling back from a closed window, the zip writer and folder walk, the push
  planner, the log rotation, the release list and the HTTP answer) run under `cargo test --workspace`.
- `cargo check -p peering-platform --target x86_64-pc-windows-msvc` and `cargo clippy -p peering-platform --target
  x86_64-pc-windows-msvc --all-targets` are clean. They compile the Windows adapters (desktop duplication, the D3D11
  device, the NV12 video processor, the Media Foundation encoder, SendInput, DPAPI, LockWorkStation) against the
  `windows` crate 0.58. Compiling is not running: none of those calls has been executed.

The host crate (tray, window, firewall and autostart executors, and the adapters in `host/src/runtime/services/windows.rs`) can also be type checked from a Mac, and linted with `cargo clippy` the same way. `ring`'s build script
needs a C compiler for the MSVC target, which only has to produce files for `cargo check`, so two stub scripts are enough.
The compiler stub creates an empty file at the path after `-Fo` (or `-o`) and exits 0. The archiver stub is called like
`lib.exe`, so it must create an empty file at the path in its `-out:PATH` argument (`/out:PATH` also occurs) and exit 0; one
that ignores `-out:` leaves the linker of the build script looking for an archive that is not there. Point
`CC_x86_64_pc_windows_msvc` and `AR_x86_64_pc_windows_msvc` at them and run
`cargo check --locked -p peering-host --target x86_64-pc-windows-msvc`. That compiles the Windows-only code and runs none of it.

Recovery and supervision, what is decided where:

- `peering-core` decides: which capture and encoder failures are worth a retry, the backoff (0.5 s doubling to 15 s), when a
  silent capture counts as stalled (30 s, doubling to 5 minutes on a still screen) and that it is then probed, and rebuilt only when
  the probe fails, the relay reconnect ladder with full jitter,
  the frame deadline (two ping intervals) and the stable minute before the ladder resets, the per-address pre-auth share, and
  how long a silent phone's keys are held (5 s).
- The pump passes run under `catch_unwind` and are held off with the same backoff after a panic. The video pass takes its
  inputs under the host state lock, then takes the coordinator out of its handle onto a blocking thread for the capture and
  encode, and locks the state again to publish, so a slow encode does not freeze input or handshakes. What the host asks
  of the coordinator meanwhile (a phone registering, a source change, a disconnect, a bitrate ceiling) is recorded as an
  intent and applied when the pass gives the coordinator back (`peering_core::video::intent`); nothing waits for the
  encode. A failure of an intent that waited (for instance a display that cannot be started) is logged and left to the
  coordinator's recovery, because there is no caller left to tell. The capture and encode always run together on that one
  thread, so the D3D11 immediate context is never used from two threads at once; that has not been run on Windows.
- A video pass that has run for 10 s (`peering_core::supervision::PassLedger`, judged by the host clock on the pump's own
  tick) is abandoned: the handle builds a new capture and encoder, which means a new D3D11 device with a new generation,
  gives them the clients, settings and display it was asked for, the window shows "did not answer", the phones get the
  standing capture-recovering notice, and the picture resumes at a keyframe after the first backoff. The thread still
  inside the old encoder is not killed, because Windows offers no safe way to do that. If its call ever returns it finds
  it was abandoned and drops what it holds. A truly wedged driver call therefore leaks one thread and the old device's
  memory until the process exits, and a driver that wedges every device keeps the host in this loop (every 10 s plus the
  backoff) rather than recovering. A monitor thread still reports a pass past 10 s to the window.

- Secrets are sealed with DPAPI and a random entropy that belongs to the install (32 bytes, minted on first start, kept in
  its own sealed file `install-entropy` beside the secrets). A process of the same user that only knows how the host
  seals, from the source, cannot open a copy of a secret file. It does not stop a process of the same user that reads the
  entropy file and unseals it too: DPAPI cannot do that, and the directory is limited to the owner already. Secrets
  sealed by an earlier build (with the fixed value in the source, or with none) are sealed again with the install's
  entropy when the host starts. An entropy file that exists and cannot be read stops the host from starting rather than
  minting a new one over secrets it protects. The DPAPI calls themselves compile for Windows and have not run.

Not verified, and not run on any machine yet:

- Loopback capture on devices that mix in an unusual format, or while the default device changes; the pointer on a hybrid GPU laptop
  and on an HDR display (the pointer is then left out); the focus rules on Chromium, Electron and UWP apps; window capture of
  windows that are elevated, protected or on another GPU; the border Windows may draw around a captured window; the folder zip on
  network drives; the update request against GitHub; the log folder button.

- The host binary and its Windows-only code: the `ui` window and tray (eframe, tray-icon), `ui/settings_view.rs`, the
  Windows adapters in `host/src/runtime/services/windows.rs`, the firewall and autostart executors, and the elevated
  firewall helper. They compile for the Windows target (see above) but have not run. The host depends on `ring`, which does not
  link from macOS.
- Running on Windows: desktop duplication frames and their reacquisition after a secure desktop, the NV12 conversion,
  the hardware and software H.264 encoders, the keyframe and bitrate changes on a live encoder, the frame rate change
  on a live encoder, input injection, the lock screen, the Run key and the firewall rule.
- The relayed UDP lane against a real relay and a real phone, and Windows UDP behaviour for it (the ICMP error on an
  unconnected socket is treated as a dropped datagram but has not been seen on Windows).
- Settings persistence: `settings.txt` is written and read by tested code, but the window's switches have not been used on a Windows
  machine. The start at login box reads the Run key when the window opens.
