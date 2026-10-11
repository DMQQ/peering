# Peering Host for Windows

Rust workspace. Plan: `docs/plans/android-and-windows.md`. Protocol: `docs/protocol.md`.

```
cd windows
cargo test -p peering-wire -p peering-core    # logic crates, no Windows API, run anywhere
```

`peering-wire` and `peering-core` MUST NOT depend on Windows APIs so they build and test on Linux and macOS.
