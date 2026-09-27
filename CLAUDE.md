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
