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

## Layout

- `crates/peering-wire`, `crates/peering-core`, `crates/peering-agent`, `crates/peering-net`: protocol, host logic,
  agent chat and identity. None of them depends on a Windows API.
- `crates/peering-platform`: the Windows adapters (desktop duplication, Media Foundation, SendInput, DPAPI). Its pure
  parts are tested on any OS.
- `host`: the process. The runtime serves clients, `ui` holds the tray and pairing window, and `autostart` and
  `firewall` hold the start-at-login and firewall helpers.

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
- `cargo check -p peering-platform --target x86_64-pc-windows-msvc` and `cargo clippy -p peering-platform --target
  x86_64-pc-windows-msvc --all-targets` are clean. They compile the Windows adapters (desktop duplication, the D3D11
  device, the NV12 video processor, the Media Foundation encoder, SendInput, DPAPI, LockWorkStation) against the
  `windows` crate 0.58. Compiling is not running: none of those calls has been executed.

The host crate (tray, window, firewall and autostart executors) can also be type checked from a Mac. `ring`'s build script
needs a C compiler for the MSVC target, which only has to produce files for `cargo check`, so two stub scripts that create empty
objects and archives are enough: point `CC_x86_64_pc_windows_msvc` and `AR_x86_64_pc_windows_msvc` at them and run
`cargo check -p peering-host --target x86_64-pc-windows-msvc`. That compiles the Windows-only code and runs none of it.

Recovery and supervision, what is decided where:

- `peering-core` decides: which capture and encoder failures are worth a retry, the backoff (0.5 s doubling to 15 s), when a
  silent capture counts as stalled (30 s, doubling to 5 minutes on a still screen), the relay reconnect ladder with full jitter,
  the frame deadline (two ping intervals) and the stable minute before the ladder resets, the per-address pre-auth share, and
  how long a silent phone's keys are held (5 s).
- The pump passes run under `catch_unwind` and are held off with the same backoff after a panic. A pass that never returns
  cannot be interrupted: the encode step shares the capture's D3D11 immediate context, which is not thread safe, so moving it
  off the runtime thread needs a multithread-protected device and is not done. A monitor thread reports a pass that has run for
  more than 10 s to the window instead. While one hangs, the connections and the relay ping stall with it.

Not verified, and not run on any machine yet:

- The host binary and its Windows-only code: the `ui` window and tray (eframe, tray-icon), `ui/settings_view.rs`, the
  Windows adapters in `host/src/runtime/services/windows.rs`, the firewall and autostart executors, and the elevated
  firewall helper. They compile for the Windows target (see above) but have not run. The host depends on `ring`, which does not
  link from macOS.
- Running on Windows: desktop duplication frames and their reacquisition after a secure desktop, the NV12 conversion,
  the hardware and software H.264 encoders, the keyframe and bitrate changes on a live encoder, the frame rate change
  on a live encoder, input injection, the lock screen, the Run key and the firewall rule.
- The relayed UDP lane against a real relay and a real phone, and Windows UDP behaviour for it (the ICMP error on an
  unconnected socket is treated as a dropped datagram but has not been seen on Windows).
- Settings persistence: the frame rate choice applies to the running host and is not saved, so the host starts again at
  60 fps after a restart. The start at login box reads the Run key when the window opens.
