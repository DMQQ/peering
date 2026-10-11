# Peering

Your Mac's screen on your iPhone. Pair the two once on your own network, then reach the Mac from
anywhere, end to end encrypted and straight between the devices where the network allows it.

[Website](https://getpeering.app) · [App Store](https://apps.apple.com/us/app/peering-remote-desktop-ssh/id6812658408)

The repository is called MacCast. The products are **Peering** (iPhone) and **Peering Host** (Mac).

## What it does

- **Remote desktop.** Live picture of a display, an app or a window, with touch, trackpad and
  keyboard input sent back. Sound and Picture in Picture on the phone.
- **Reach it from anywhere.** Devices try a direct path first (hole punching) and fall back to a
  relay when the network refuses one. No account: each device mints its own key and stores it in
  its Keychain.
- **Pair with a code.** Both screens show six digits; confirming them pins each side's public key.
- **Coding agents.** Run Claude Code, Codex or OpenCode on the Mac, chat with them from the phone,
  review diffs, commit and push, and answer permission prompts from the Lock Screen.
- **Terminal and SSH.** Shells on the Mac or on any server you add.
- **Files.** Browse, preview, edit, upload and download on the Mac or over SSH.
- **Virtual displays.** Give the phone its own screen instead of mirroring the Mac's.

## Privacy model

The relay cannot read anything it carries. Control traffic is a TLS session between the two ends
that the relay copies without terminating, and video is sealed with a key the relay was never told.
That property is the product, and `relay/` is kept deliberately too simple to break it. See
[relay/README.md](relay/README.md).

## Repository layout

| Path | What it is |
|---|---|
| `apple/` | The iOS and macOS apps, their packages and scripts, built from one Xcode project |
| `apple/MacCast/` | The iOS app (Peering) |
| `apple/MacCastHost/` | The macOS app (Peering Host): capture, encode, input injection |
| `apple/MacCastKit/` | Logic that needs no UI framework: agent parsing, review, plans, formatting. Has the tests |
| `apple/RemoteCore/` | Shared protocol, framing, crypto and coordinate mapping |
| `apple/SSHCore/` | SSH client used by the terminal and file browser |
| `relay/` | `peeringd`, the Rust relay, and the marketing site in `relay/site/` |
| `apple/MacCastWidget/`, `apple/MacCastHostWidget/`, `apple/Shared/` | Widgets and Live Activities |
| `apple/MacCastTests/`, `apple/MacCastUITests/` | App-level tests |
| `apple/Tools/`, `relay/tools/` | Build, install and check scripts; relay and site deploy scripts |
| `marketing/` | App Store art, social media and release material |
| `docs/` | Research notes |
| `wiki/` | Design system, domain glossary, plans and App Store copy |

## Requirements

- Xcode with Swift 6
- iOS 18.0 and macOS 15.0 deployment targets
- Rust (see `relay/rust-toolchain.toml`) to build the relay

## Building

Always build with `-scheme`. With `-target` the build settings that make the targets work are not
applied.

```sh
# iOS app
xcodebuild -project MacCast.xcodeproj -scheme MacCast \
  -destination 'generic/platform=iOS' -derivedDataPath build/ios build

# Mac host
xcodebuild -project MacCast.xcodeproj -scheme MacCastHost \
  -configuration Debug -derivedDataPath build/host build
```

The Mac host is not sandboxed on purpose: a sandboxed app cannot post input events into other
apps, which is its whole job. It is distributed outside the Mac App Store, updated through Sparkle.

## Testing

```sh
apple/Tools/check.sh           # package tests, then a compile of both apps
apple/Tools/check.sh --quick   # package tests only

cd apple/MacCastKit && swift test
cd relay && cargo test
```

New logic goes in `MacCastKit` or `RemoteCore` with Swift Testing tests, so it can be checked
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
