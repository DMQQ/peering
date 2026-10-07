# MacCast / Peering

## Design system

[DESIGN.md](DESIGN.md) is the authority on the visual language: colour, type, surfaces, spacing,
motion, and the phone frame used in the tour and on the marketing site.

**Read it before** writing or changing any SwiftUI view, building App Store screenshots or
marketing art, or reaching for a colour, font, radius or padding value. It exists so new UI lands
next to the existing UI rather than beside it.

The source files it documents are still the final word when the two disagree:
`MacCast/Theme.swift` (client) and `MacCastHost/Theme.swift` (Mac host).

Two rules from it that are easy to break by accident:

- **No accent hue except the one state blue.** The palette is opacities of white, because the
  picture inside the frame is the only thing entitled to a colour.
- **Cards are outlined, never filled.** A translucent white fill collapses page, card and row into
  three greys a few points apart.

## Working notes

[AGENTS.md](AGENTS.md) carries everything about this repo that is not derivable from reading the
source, including traps that have cost hours. Read it before touching capture, crypto, or input.

## Comments

Write a comment only when the code cannot say it:

- **Logic that is not obvious** from reading the code, in a line or two.
- **A trap already hit**: an approach that failed or a cause that took real time to find, so
  nobody tries it again. Say what broke and why, briefly.

Nothing else: no comment restating what the code does, no history of how it came to be, no
design essay. A long justification goes stale and misleads.

## Code standards

The repo is meant to be read by strangers. Before calling work done, check it against this list.

**Structure**

- Code lives in a feature folder (`MacCast/Agent/Chat/`, `MacCastHost/Agent/Sessions/`), never loose
  at the root of a target. A new file goes next to the files it works with.
- One main type per file, named after it. `Type+Topic.swift` only for an extension of that type.
- A file stays under about 300 lines and a function under about 40. Past that, split by
  responsibility, extracting whole declarations. Never cut a line range out of a dense file.
- Anything decidable without SwiftUI, UIKit or AppKit (parsing, queueing, formatting, policy,
  state decisions) belongs in `MacCastKit` or `RemoteCore`, with tests. Views and host glue stay thin.

**Code**

- A third copy of a block becomes a helper. Two near-identical closures or request builders already do.
- No force unwrap, `try!` or `fatalError` unless the case is provably unreachable and a line says why.
- No `try?` where a failure would matter to the user (a write that loses their data, a launch that
  does not happen). Throw it or log it.
- Default to `private`. Widen only as far as another file needs. `public` is for the packages' API.
- Names say what a thing is: no abbreviations, no `Manager`, `Helper` or `Util` for a new type that
  has a more exact name, and a Bool reads as a statement (`adapterLive`, not `live`).
- No commented-out code, no `print`, no TODO without a reason, no dead parameters or unused cases.
- User-visible text goes through `String(localized:)`.

**Concurrency (Swift 6)**

- `@unchecked Sendable` only on a class whose every mutable property is guarded by one lock or one
  queue, and a line says which. Callbacks a C API invokes are marked `@Sendable` explicitly.
- Never call out while holding a lock. Work out what to do under it, act after it.

**Tests**

- New logic ships with Swift Testing tests (`@Test`, `#expect`), named for the behaviour, with no
  sleeps and nothing shared between tests. Existing XCTest files stay as they are.
- A bug fix gets the test that would have caught it.

**Wire and release**

- The app has no deployed users yet. Change wire types freely: do not bump `ProtocolInfo.version`
  and do not add compatibility guards for older peers until a build has shipped.

**Public repo hygiene**

- No personal paths, emails, team IDs or tokens in tracked files. Scratch output (transcripts,
  screenshots, session dumps) is never written to the repo root.
- Commit messages are one imperative line that says what changed and why it matters.

**Checking work**

- Build with `-scheme` and a private `-derivedDataPath`; run `swift test` in `MacCastKit`. Report
  what was run, and say plainly what was not.
