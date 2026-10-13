# Peering

Your computer's screen on your phone. Pair the two once on your own network, then reach the computer
from anywhere, end to end encrypted and straight between the devices where the network allows it.
Phones: iPhone and Android. Computers: Mac, and Windows (in progress).

[Website](https://getpeering.app) · [App Store](https://apps.apple.com/us/app/peering-remote-desktop-ssh/id6812658408)

The products are **Peering** (iPhone and Android) and **Peering Host**
(Mac and Windows).

| | Phone app | Host app | State |
|---|---|---|---|
| Apple | iPhone, `apple/Peering/` | Mac, `apple/PeeringHost/` | Shipped, App Store |
| Android | `android/` | | In testing on a device, not yet on Google Play |
| Windows | | `windows/` | Rust host, built and tested on a Mac for the logic only, never run on Windows |

## What it does

- **Remote desktop.** Live picture of a display, an app or a window, with touch, trackpad and
  keyboard input sent back. Sound and Picture in Picture on the phone.
- **Reach it from anywhere.** Devices try a direct path first (hole punching) and fall back to a
  relay when the network refuses one. No account: each device mints its own key and stores it in
  its Keychain.
- **Pair with a code.** Both screens show six digits; confirming them pins each side's public key.
- **Coding agents.** Run Claude Code, Codex or OpenCode on the Mac, chat with them from the phone,
  review diffs, commit and push, and answer permission prompts from the Lock Screen.
- **Terminal and SSH.** Shells on the computer or, on iPhone, on any server you add.
- **Files.** Browse, preview, edit, upload and download on the Mac or over SSH.
- **Virtual displays.** Give the phone its own screen instead of mirroring the Mac's.

## Android app

Peering for Android is a native Kotlin app (Jetpack Compose, Material 3, minSdk 29) that pairs with a Mac or a
Windows host and does what the iPhone app does. It is in testing on devices and not on Google Play yet.

- **Connect and pair.** Nearby computers over mDNS, six digit code pairing with a QR scanner, connect by address or
  by device ID, and the same direct-then-relay path as the iPhone. A paired computer's key is pinned.
- **Remote screen.** Picture with trackpad, touch and joystick pointer modes, keyboard, clipboard, sound, and a
  picker for displays, apps, windows, desktops and virtual displays, including the mosaic.
- **Coding agents.** Chats with Claude Code, Codex and OpenCode, changes review, permission prompts answered from
  a notification, and a home screen widget.
- **Terminal, SSH and files.** Shells on the computer or on any SSH server you add, and a folder browser with
  search, preview, upload and download.
- **Stays connected.** A foreground service keeps a session alive in the background, and the app reconnects by
  itself when the network changes.
- **Localised** in the same ten languages as the iPhone app.

Not built yet: push when the app is fully closed, video preview in files, photo upload, and analytics.
The full comparison is in [docs/reviews/android-feature-parity.md](docs/reviews/android-feature-parity.md).

```sh
cd android
./gradlew :app:installDebug      # build and install on a connected phone (USB debugging on)
./gradlew :core:wire:test :core:session:test :app:testDebugUnitTest
```

`core/wire` and `core/session` are plain Kotlin with no Android classes, so their tests run on a laptop. Release
builds, signing, wireless debugging and the background behaviour are covered in [android/README.md](android/README.md).

## Windows host

Peering Host for Windows is a Rust workspace that lets the same iPhone and Android apps reach a Windows PC. It
speaks the same wire protocol as the Mac host (`docs/protocol.md`), listens on TCP 51515 for the local network and
registers with the relay for everything else, and shows its pairing code in a tray window. **It has been built and
tested on a Mac for its logic only and has never been run on Windows**, so treat it as a preview.

- **Picture and input.** Desktop Duplication capture of a display, a single window through Windows.Graphics.Capture,
  hardware or software H.264 encoding, mouse and keyboard injection, and the cursor drawn into the picture.
- **Sound** from the PC through WASAPI loopback, sent only while a phone is in the foreground.
- **Clipboard, files and terminal.** Text and image clipboard, folder browsing with zip download, and shells.
- **Agents and hooks.** Claude Code, Codex and OpenCode chats, approval pushes through the relay, and the opt-in
  terminal hooks.
- **Hosting niceties.** Text field awareness through UI Automation, a rotating log file with an Open log folder
  button, a daily update check, start at sign-in, and a firewall rule helper.
- **Safety.** The device key is sealed with DPAPI, and every paired phone is pinned by its public key.

Not built: whole application capture and thumbnails, a real privacy curtain, desktop switching, virtual displays,
Live Activity pushes and code signing. See [docs/reviews/windows-feature-parity.md](docs/reviews/windows-feature-parity.md).

```sh
cd windows
cargo test --workspace                    # runs on any OS: in-memory streams and fakes
cargo build --release -p peering-host     # on Windows, with the Visual Studio C++ build tools
powershell -ExecutionPolicy Bypass -File installer\build.ps1   # Inno Setup installer, unsigned
```

The crates are `peering-wire` (protocol), `peering-core` (sessions and policy), `peering-net` (LAN, relay, direct
path), `peering-platform` (capture, input, audio, files) and `peering-agent` (coding agents). Details, the first-run
SmartScreen warning and the checklist of things only a Windows machine can verify are in
[windows/README.md](windows/README.md).

## Privacy model

The relay cannot read anything it carries. Control traffic is a TLS session between the two ends
that the relay copies without terminating, and video is sealed with a key the relay was never told.
That property is the product, and `relay/` is kept deliberately too simple to break it. See
[relay/README.md](relay/README.md).

## Repository layout

| Path | What it is |
|---|---|
| `apple/` | The iOS and macOS apps, their packages and scripts, built from one Xcode project |
| `apple/Peering/` | The iOS app (Peering) |
| `apple/PeeringHost/` | The macOS app (Peering Host): capture, encode, input injection |
| `apple/PeeringKit/` | Logic that needs no UI framework: agent parsing, review, plans, formatting. Has the tests |
| `apple/RemoteCore/` | Shared protocol, framing, crypto and coordinate mapping |
| `apple/SSHCore/` | SSH client used by the terminal and file browser |
| `android/` | The Android app (Kotlin, Compose, Material 3): `core/wire` and `core/session` are plain Kotlin with JVM tests, `core/platform` and `app/` use Android. Home screen widgets for Quick Connect and Agents. See [android/README.md](android/README.md) |
| `windows/` | The Windows host (Rust workspace): protocol, networking, capture and input, a tray window for the pairing code. See [windows/README.md](windows/README.md) |
| `relay/` | `peeringd`, the Rust relay, and the marketing site in `relay/site/` |
| `apple/PeeringWidget/`, `apple/PeeringHostWidget/`, `apple/Shared/` | Widgets and Live Activities |
| `apple/PeeringTests/`, `apple/PeeringUITests/` | App-level tests |
| `apple/Tools/`, `relay/tools/` | Build, install and check scripts; relay and site deploy scripts |
| `marketing/` | App Store art, social media and release material |
| `docs/` | Research notes, the wire protocol (`docs/protocol.md`) and the Android and Windows plans in `docs/plans/` |
| `wiki/` | Design system, domain glossary, plans and App Store copy |

## Requirements

- Xcode with Swift 6
- iOS 18.0 and macOS 15.0 deployment targets
- Rust (see `relay/rust-toolchain.toml`) to build the relay
- Android: JDK 17 and the Android SDK (platform 35)
- Windows host: Rust and the Visual Studio C++ build tools, on a Windows machine

## Building

Always build with `-scheme`. With `-target` the build settings that make the targets work are not
applied.

```sh
# iOS app
xcodebuild -project Peering.xcodeproj -scheme Peering \
  -destination 'generic/platform=iOS' -derivedDataPath build/ios build

# Mac host
xcodebuild -project Peering.xcodeproj -scheme PeeringHost \
  -configuration Debug -derivedDataPath build/host build
```

The Mac host is not sandboxed on purpose: a sandboxed app cannot post input events into other
apps, which is its whole job. It is distributed outside the Mac App Store, updated through Sparkle.

The Android app and the Windows host have their own build and run steps:

```sh
cd android && ./gradlew :app:assembleDebug          # Android app
cd windows && cargo build --release -p peering-host # Windows host, on Windows
```

## Testing

```sh
apple/Tools/check.sh           # package tests, then a compile of both apps
apple/Tools/check.sh --quick   # package tests only

cd apple/PeeringKit && swift test
cd relay && cargo test
cd android && ./gradlew :core:wire:test :core:session:test :app:testDebugUnitTest
cd windows && cargo test --workspace
```

New logic goes in `PeeringKit` or `RemoteCore` with Swift Testing tests, so it can be checked
without a phone.

## Running the relay locally

```sh
cd Relay
cargo run    # signalling on :8443, control on :9443
```

Point both apps at `127.0.0.1` to try it. Configuration and deployment are in
[relay/README.md](relay/README.md).

## Contributing and working notes

- [CLAUDE.md](CLAUDE.md) holds the code standards: file and function size, naming, comment policy,
  concurrency rules.
- [AGENTS.md](AGENTS.md) records the traps that cost hours, in capture, crypto and input. Read it
  before touching those.
- [wiki/DESIGN.md](wiki/DESIGN.md) is the visual language. Read it before writing any UI.
- [wiki/CONTEXT.md](wiki/CONTEXT.md) is the domain glossary.
