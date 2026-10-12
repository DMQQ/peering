# Android Terminal parity

Redone from the Swift source. Sources read in full: `apple/MacCast/Terminal/TerminalScreen.swift`, `TerminalDeck.swift`, `TerminalCommandField.swift`, `TerminalPalette.swift`, `TerminalCards.swift` (empty state), `TerminalEndPrompt.swift`, `TerminalHubScreen*.swift`, `HubTabs.swift`, `Connection/TabStrip.swift`, `Remote/InputBarStyle.swift`, `Remote/RailButtons.swift`, `Design/Theme.swift`, `MacCastKit/TerminalMetrics.swift`. The marketing screenshots in `marketing/appstore/raw/en` contain no terminal screen, so values come from the code only. Nothing was run on a device or emulator.

The previous version of this file claimed a match and listed rows that were not true. The rows below replace it. Status: fixed, kept (Android-appropriate), or open.

## Differences found and fixed

| # | Element | iPhone (Swift) | Android before | Now |
|---|---------|----------------|----------------|-----|
| 1 | Header | Inside the hub the switcher is the header. The pushed terminal page has a nav bar, but the hub tab has none | Back arrow plus a "Terminal" title plus an end cross above the tab strip, under the hub's own switcher and close button | `TerminalRoute(hosted = true)` draws no bar. Rename is a double tap or long press on a tab, end is the tab's cross |
| 2 | Files root | Files page has no back arrow | Back arrow in the folder bar | `FilesRoute(hosted = true)` hides it. Preview and search bars keep theirs. System back still goes up a folder, then closes the hub |
| 3 | Output colours | xterm defaults: black, `cd0000`, `00cd00`, `cdcd00`, `0000ee`, `cd00cd`, `00cdcd`, `e5e5e5`, bright `7f7f7f`, `ff0000`, `00ff00`, `ffff00`, `5c5cff`, `ff00ff`, `00ffff`, `ffffff` | A custom pastel set tuned for the app | The xterm values, so `ls` and `git` colours match |
| 4 | Cursor | None drawn. The log is text | A translucent blue block | Removed |
| 5 | Output padding | 12 pt on all four sides | 8 dp horizontal, 0 vertical | 12 dp all round |
| 6 | Line height | Natural line height of the monospaced face (about 1.2) | 1.3 | 1.2 |
| 7 | Command capsule | 48 pt glass capsule (`surface` white 7 percent over the black bar), 1 pt outline gradient white 20 percent to 5 percent top to bottom, 14 pt side padding | Filled `containerHigh` with a flat hairline | White 7 percent fill with the same gradient outline |
| 8 | Command field | 30 pt tall, monospaced 17, white caret, quotes in caution yellow, operators `\| ; & > < ( )` in blue, `$VAR` white 65 percent, flags white 50 percent | Monospaced 17, blue caret, no colouring | 30 dp, white caret, `CommandHighlight` (a port of the Swift scanner, unit tested) as a visual transformation |
| 9 | Send button | 48 circle, glyph 17 bold, ink fill when enabled, white 10 percent when not, press scale 0.92 | 22 dp glyph, no press feel | 20 dp glyph, scale 0.92 and 60 percent opacity while held |
| 10 | Deck keys | Ellipsis 36 by 44 radius 9, esc tab and ctrl-C 38 by 44 radius 7, each fill white 10 percent plus 0.5 pt white 16 percent border; arrows 44 tall joined group, 1 pt gaps, clipped to radius 9, fill white 10 percent, glyph 21 medium. Press: scale 0.9, 0.88, 0.92 and opacity 0.6 | Ellipsis had no border, radius 8 everywhere, ripple | Radii 7 and 9, border on the ellipsis, press scale and fade (`railPress`), no ripple |
| 11 | Tab | 10 pt side padding both sides, cross 22 by 32 with a 9 pt bold glyph, mark glyph 11 semibold | 10 pt on the left only, 32 by 32 cross with an 11 dp glyph, 13 dp mark | 10 dp both sides, 22 by 32 cross with a 10 dp glyph, 12 dp mark |
| 12 | Empty state | A mock window (38 pt title strip with three 8 pt dots, hairline, 74 pt body of black 35 percent holding a typed command in monospaced 14), radius 20 with the 20 to 6 percent outline gradient, then "No terminals yet" in the bold serif at 24 with tracking -0.6, then a footnote | A tile icon with a Material title | The same window (static command, no typing loop), serif title, footnote, and a "New terminal" button |
| 13 | Starting state | Blue prompt, caret 9 by 16 radius 1.5 in white blinking, "Starting login shell" with cycling dots | Same, but the whole screen recomposed every tick | Caret drawn in the draw phase, dots recompose only when they change |
| 14 | Sheet | Detents medium and large, drag handle, backdrop colour, group labels footnote semibold secondary, key chip radius 7, cards radius 12 outlined white 14 percent | Always full height, `sheet` grey | Backdrop colour, medium and large detents, chip radius 7 |
| 15 | Smoothness | The log is one text view | Each output event rebuilt the whole screen snapshot on the main thread in composition and recomposed the route, strip and canvas | `TerminalSessions.frames(id)` publishes snapshots from a background scope at most once per 16 ms. The canvas reads the frame only while drawing. Tabs no longer change on output, so nothing recomposes |

## Kept on purpose

| Element | Reason |
|---------|--------|
| "+" at the end of the tab strip | The iPhone makes a shell on its hub list page. Android has no such page, so the button is the way to start one |
| Copy screen in the tab menu | The canvas has no text selection, where the iPhone has `textSelection` |
| Ripples on sheet rows and menu items, system back, IME insets | Android behaviour |
| Material icon set for glyphs | SF Symbols are not available. Sizes were matched, shapes differ slightly |
| Default font | The iPhone uses SF Mono. Android uses the system monospace |
| Segmented control for text size | The system segmented control on each platform |

## Still different (open)

| Element | iPhone | Why it remains |
|---------|--------|----------------|
| Terminals list page | The Terminals tab is a list of window cards (`TerminalWindowCard`) with a heading, a guide card and history, and a tap opens one shell on a pushed page with its own tab strip | The Android tab shows the shells directly. Building the card list is a separate feature, and the user asked for no extra top level chrome |
| Files toggle in the terminal bar | Browses the shell's folder | Android keeps files on its own tab |
| Tour tips and the end-of-line "Done" accessory | iOS first-run tours, keyboard accessory | No equivalent on Android, the hide-keyboard key in the capsule covers Done |
| Error and warning word tint on uncoloured lines | `TerminalStyledLine.kind` tints lines that look like errors | The Android emulator does not classify lines |
| Glass material | iOS 26 `glassEffect` samples what is behind the capsule | Not reproducible, the flat white 7 percent fill with the outline is the Swift fallback's look |
| Sticky bottom while scrolled up | Output keeps the view where the user left it | The canvas follows the tail, scrolling back is relative to the bottom |
| Press feedback haptic | Optional on the iPhone, off in the terminal | Not applicable |
