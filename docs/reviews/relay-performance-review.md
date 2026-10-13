# Relay performance review (peeringd v0.2.12)

Read-only review of `relay/`. Nothing was run against production, nothing was measured. Every
number below that is not a line reference is an estimate and is labelled as one. Paths are relative
to `relay/`.

## Verdict

The per-packet and per-byte paths are clean. There is no lock held across an await on a hot path, no
allocation per UDP datagram, no file IO on a runtime thread in the session path (one rare exception,
A4), and the recent hardening (per-IP limits, idle timeout, quota metering) costs tens of
nanoseconds per read, not microseconds. The relay is unlikely to be CPU bound at any realistic load
for a single box.

What can make a session feel slow is mostly not in the code's hot loops. In order of expected
user-visible impact:

1. Kernel and box settings (UDP socket buffers, congestion control, send queue depth).
2. Sharing runtime threads between the video forwarder and everything else, on a small box.
3. A stalled `send_to` stalling every session's video.
4. The musl allocator (signalling and handshake cost, not the packet path).
5. Distance (single region), which no code change fixes.

## A. Real problems found

None of these breaks sessions. Ranked by how likely they are to be felt.

### A1. The video socket uses the kernel default receive buffer (medium likelihood, medium impact)

`src/udp_relay.rs:76-80` binds with `UdpSocket::bind` and never sets `SO_RCVBUF` or `SO_SNDBUF`.
`socket2` is not a direct dependency (`Cargo.toml`), so nothing can set them today. On Linux the
default is `net.core.rmem_default`, usually 212992 bytes.

Why it matters: every session's video from the Mac arrives in bursts (a keyframe is many packets
back to back at the sender's line rate), all on one socket. When the forwarder task is not running
for a few milliseconds (see A2), or two sessions burst at once, the 208 KiB queue overflows and the
kernel drops datagrams silently. The relay cannot see this: `dropped` in `forward` counts only
unrouted datagrams, not kernel overruns. The user sees a smear or a frozen frame until the next
keyframe.

At 20 Mbps, 208 KiB is about 83 ms of one stream, and less with several. Estimate, not measured:
drops here would be rare with one or two sessions and become visible with several active at once.

Fix: raise the buffers to 4 to 8 MiB. Needs `socket2` (or `libc`) and `net.core.rmem_max` and
`wmem_max` raised on the box, otherwise the request is silently clamped. Check on the box with
`nstat -az | grep -i RcvbufErrors` and the drops column in `/proc/net/udp`. That is the measurement
that tells whether this is a live problem; I could not take it.

### A2. The video forwarder shares workers with everything else (likelihood depends on core count, which I could not see)

`src/main.rs:19` uses `#[tokio::main]` with defaults, so worker threads equal the box's cores. The
forwarder (`udp_relay.rs:100`) is spawned beside the control accept loop, signalling, TLS
handshakes, the web server and the sweep (`main.rs:99-116`). tokio-rustls does its handshake crypto
inside `poll`, on a worker. On a 1 or 2 vCPU box a handshake burst (reconnect storm after a deploy,
a scan, many phones waking) delays the forwarder by however long the handshake work takes, which is
the jitter source for every live video stream. A 2048-bit RSA signature is on the order of a
millisecond (estimate; an ECDSA certificate is several times cheaper, and I could not see which the
box has).

Fix: run the forwarder on its own OS thread with its own `current_thread` runtime. That isolates
video latency from signalling load entirely. Low risk, small change because `bind_forwarder`
already returns the future (`udp_relay.rs:94-102`).

### A3. One slow `send_to` stalls every session (low likelihood, high blast radius)

`udp_relay.rs:178` does `socket.send_to(...).await` inside the single receive loop. For a UDP socket
`send_to` waits for writability when the socket send buffer is full, and while it waits the loop
reads nothing, so every other session's datagrams queue behind it (and overflow, see A1). A full
send buffer needs the egress path to be congested or rate limited, which is not normal on a
datacentre uplink, so this is a tail risk.

Fix: use `try_send_to` and count a drop on `WouldBlock`. For realtime video a dropped datagram is
the correct behaviour anyway; waiting only adds latency to a packet that is already late. Tiny
change.

### A4. Referral writes do a blocking `fsync` on a runtime thread (low frequency, small impact)

`src/referrals.rs:306-313` opens the file, writes and calls `sync_data` synchronously. The callers
(`src/signalling/referral.rs:74` and `:94`) are in async handlers, so the fsync blocks a tokio
worker for the disk's flush time (typically 1 to 10 ms on a VPS, occasionally tens). It happens
only when creating a code or redeeming an invite, so it is rare, and the lock is correctly released
before the write (`ensure_code` returns the line to write after the lock). It is the only place I
found file IO on a worker.

The other two writers are done correctly: the usage log has its own thread, a bounded queue,
batches and one fsync per batch, and `record` uses `try_send` (`usage_log.rs:296-381`,
`quota.rs:347-375`); device bindings do the same (`device_bindings.rs:139-146`, `:296-312`,
`try_send`, never blocks). Fix for referrals: reuse that writer-thread pattern, or wrap in
`spawn_blocking`. Low priority.

### A5. musl default allocator (medium likelihood, small to medium impact, signalling side only)

The release binary is built for `x86_64-unknown-linux-musl` (`.github/workflows/relay.yml:60`,
`Dockerfile:46`) and `Cargo.toml` has no allocator override and no `[profile.release]` section.
musl's malloc is known to be slow and to serialise on a global lock under multithreaded
allocate-and-free churn (well established generally; I did not measure it on this workload).

This does not touch the UDP path (no allocation per datagram) and barely touches the control splice
(no allocation per read). It does affect signalling: WebSocket framing, JSON encode and decode,
TLS handshake state and per-connection buffers, all allocating from several workers at once.
Effect: connect latency under load and CPU on the small box. Fix: `mimalloc` as the global
allocator. It builds from C with the `musl-gcc` the pipeline already installs. Risk is low; the
gain is an estimate, and for a handful of simultaneous connects it will not be noticeable.

### A6. Verbose logging left on in production (small impact)

The default is `info` (`src/main.rs:22-24`). A DEBUG line per failed handshake in the live journal
means `RUST_LOG` is set to something verbose in `/etc/peeringd.env` (I could not read the box).
`EnvFilter` with a bare `debug` also turns on debug output of every dependency, including
tungstenite, h2 and rustls (the `logging` feature is enabled in `Cargo.toml`). None of that is in
the per-packet or per-byte path, so it costs journald work and disk, not video latency. Set
`RUST_LOG=info` (or `info,peeringd=debug` when actually diagnosing), and find out what connects and
fails the handshake every second. The repo's own health check runs every 5 minutes and probes with
curl to `:8080` and a bare TCP connect (`deploy/peeringd-healthcheck.sh`, `.timer`), so the
once-per-second prober is something else (an external monitor, a load balancer, or Cloudflare).
Each one costs a TLS accept on a worker.

## B. What I checked and found fine

Evidence, so nobody re-audits these.

**UDP forwarder per packet** (`udp_relay.rs:122-182`, `session.rs:263-300`):
- The receive buffer is allocated once (`:105`). No allocation per datagram.
- `route_sized` takes one `std::sync::Mutex`, does up to three `HashMap` lookups with the default
  SipHash on a 16 byte key, writes two fields and reads the clock once. My estimate is 100 to 200 ns
  against 2 to 4 microseconds for the two syscalls (`recv_from`, `send_to`) that dominate. The lock
  is never held across the send. The only other takers are `open`, `close`, `peer_address` and
  `reap` (every 10 s, linear in routes, at most 2000 routes at the 1000 session cap, well under a
  millisecond). Contention is not a problem.
- A cheaper hasher would save under 1 percent. Not recommended.
- Throughput ceiling of the single loop: two syscalls per packet suggests something like 150k to
  400k packets per second on one core (estimate). A 20 Mbps stream of 1200 byte packets is about
  2000 packets per second per direction, so the loop saturates at roughly 50 or more simultaneous
  heavy sessions. The box's uplink will bind first.

**Control splice** (`tcp_relay.rs:150-260`, `counted_stream.rs`):
- `copy_bidirectional` uses tokio's default 8 KiB buffer per direction. The added cost per read in
  `CountedStream` is one `Instant::now` (vDSO, about 20 ns), one `fetch_add` and one `fetch_max`
  (relaxed atomics): around 50 ns per read, not per byte. Metering and idle accounting are not
  noticeable.
- The `select!` loop (`tcp_relay.rs:187-214`) only iterates when the meter tick or the idle sleep
  fires. The splice future is pinned and polled through `&mut`, so traffic does not cause loop
  iterations and the idle `sleep` is not rebuilt per byte. The idle timeout adds a timer wake per
  session per tick, nothing more.
- `registry.touch` per tick takes the async `Mutex` for a map get and an assignment. All `Registry`
  operations hold the lock only across non-await code, and `sweep` is linear in sessions every
  30 s.
- `set_nodelay(true)` is applied to every accepted control socket (`tcp_relay.rs:67`). Confirmed.

**Signalling** (`signalling/*.rs`, `hosts.rs`): the `HostRegistry` async mutex is held only for a
map operation, and `entry_for` clones the sender out so the lock is not held while a session is
allocated. The device binding check is an in-memory map behind a std mutex with `try_send` to a
writer thread. Receipt verification is cached per connection (`storekit.rs` `seen`, line 610). The
first verification per connection is synchronous certificate-chain crypto on a worker (about 1 to 3
ms, estimate), which matters only in a reconnect storm.

**Per-IP limiter** (`limits.rs`): a `std::sync::Mutex` over a map, touched at accept and session
allocation, pruned above 4096 entries (`limits.rs:15`). Not per packet or per byte.

**Resource limits**:
- File descriptors: `LimitNOFILE=65536` (`deploy/peeringd.service`). Needs are signalling up to
  4096 (`config.rs:209`), control up to 2 per session x 1000 sessions plus up to 512 unauthenticated
  (`tcp_relay.rs:34`), a UDP socket and a few files. Well under the limit.
- Memory: the maps are bounded (sessions 1000, signalling sockets 4096, per-IP table pruned, device
  bindings, referrals and usage mirror all capped). Per splice, two 8 KiB buffers plus kernel socket
  buffers. No unbounded growth found.
- Panics: tasks run under a supervisor (`supervise.rs`, `main.rs:60-75`); a core task ending takes
  the process down for systemd to restart. That design relies on unwinding, see the note below.

## C. Optional speedups, ranked

Gains are estimates unless stated.

| # | Change | Gain | Risk | Effort |
|---|--------|------|------|--------|
| C1 | Raise UDP `SO_RCVBUF`/`SO_SNDBUF` to 4 to 8 MiB, plus `net.core.rmem_max`/`wmem_max` | Removes burst drops on the video socket. Visible only if A1 drops are happening; measure first | Very low | Small: add `socket2`, a sysctl file on the box |
| C2 | Forwarder on its own OS thread and runtime (A2) | Removes handshake-induced video jitter on 1 to 2 core boxes; nothing on larger ones | Low | Small |
| C3 | `try_send_to` in the forwarder (A3) | Removes a tail risk, no change in the normal case | Very low | Tiny |
| C4 | `net.ipv4.tcp_congestion_control=bbr` with `net.core.default_qdisc=fq` on the box | For TCP relayed to far or lossy (mobile) clients: higher throughput and less queueing under loss, on the TCP fallback and the signalling sockets. Meaningful for transatlantic users, little for near ones | Low (reversible sysctl), but test on the real path | Tiny |
| C5 | `net.ipv4.tcp_notsent_lowat` (for example 131072) | Caps the unsent queue toward a slow client, so stale control data does not queue for seconds (autotuned `tcp_wmem` max is typically 4 MiB, which at a few Mbps is seconds). A guess: helps only when a client's downlink degrades while video is on TCP. Global setting, affects every TCP socket | Low to medium (too low hurts throughput on long paths) | Tiny |
| C6 | `mimalloc` global allocator (A5) | Cheaper signalling and handshakes under concurrency; nothing on the packet path | Low | Tiny |
| C7 | `[profile.release]` with `lto = "thin"`, `codegen-units = 1` | A few percent CPU at best; hot paths are syscall bound, so user-visible gain is near zero. Slower builds | Very low | Tiny |
| C8 | `RUST_LOG=info` (A6) | Less journald churn, no dependency debug logging | None | Trivial |
| C9 | Larger splice buffer with `copy_bidirectional_with_sizes` (32 to 64 KiB) | Fewer syscalls only if the TCP fallback carries very high bitrate. At 20 Mbps an 8 KiB buffer is about 300 reads per second per direction. Does not reduce latency. Worst-case memory 128 MiB at 64 KiB x 1000 sessions | Very low | Tiny. Not worth doing |
| C10 | Referral writes off the worker (A4) | Removes rare 1 to 10 ms stalls | Low | Small |
| C11 | `recvmmsg`/`sendmmsg`, or several sockets with `SO_REUSEPORT` | Matters only beyond the single loop's estimated ceiling. The route table is already shared, so reuseport would work, but hashing behaviour under NAT rebinding needs testing | Medium | Medium |
| C12 | io_uring | Only at very high packet rates | Medium to high (needs a separate runtime, and the unit's hardening may block it) | Large. Not worth it at this scale |
| C13 | A second region (US) | By far the largest user-visible gain for far-away users: relay RTT is the floor of every control round trip and of the TCP fallback, and a US user pays about twice the transatlantic RTT today. Nothing above comes close | Operational: second box, a way for the host or client to pick a nearer relay; session state is per process so both ends of a session must use the same relay | Large |

**Do not do: `panic = "abort"`.** It looks like a free release-profile speedup, but the supervisor
design (`supervise.rs`, `main.rs:60-75`) and the per-connection `tokio::spawn` rely on a panic in
one task being contained. With abort, one message that panics takes down every live session. The
gain is a few percent of binary size.

**Not recommended: `target-cpu=native`.** CI builds on a GitHub runner and the box is a different
CPU, so a wrong target gives an illegal-instruction crash on deploy. The hot paths are syscalls, and
`ring` already selects its SIMD paths at runtime.

## D. What I could not measure

- Core count and RAM of the Helsinki box, so A2's real exposure is unknown.
- Whether the box's TLS certificate is RSA or ECDSA (handshake cost).
- Actual kernel UDP drop counters (A1).
- The sysctl state of the box (`rmem_max`, congestion control, `tcp_wmem`).
- What sends a failing handshake every second.
- Actual packets per second at peak, to compare with the single-loop ceiling.
- No benchmarks were run; the repository has none for the packet path. I did not run the test suite
  or clippy because nothing was changed.

Suggested measurements before changing anything: the two kernel counters in A1, `nproc`, `ss -tin`
on a live spliced session (look at `send-q` and `cwnd`), and `RUST_LOG` in `/etc/peeringd.env`.

## E. Suggested order of work

1. On the box: check the counters in D. Set `RUST_LOG=info`. Add a sysctl drop-in for
   `rmem_max`/`wmem_max`, BBR and `fq`. All reversible, no deploy needed.
2. In code, one small release: socket buffers (C1), `try_send_to` (C3), forwarder on its own thread
   (C2), `mimalloc` (C6). Each is a few lines, and the existing tests in `udp_relay.rs` cover
   forwarding.
3. Referral writer (C10) when convenient.
4. Decide on a second region when user distribution says so; it is the one item here that changes
   how the product feels for far-away users.
