# Android Terminal parity checklist

Source: `apple/MacCast/Terminal/TerminalScreen.swift`, `TerminalDeck.swift`, `TerminalEndPrompt.swift`, `TerminalCards.swift` (empty state), `TerminalCommandField.swift`, `Connection/TabStrip.swift`, `Remote/InputBarStyle.swift`, `SSH/SSHQuickCommands.swift`.

Screen column top to bottom: navigation bar, tab strip with a hairline under it, output, optional history strip, deck (hairline above), input bar (48 dp capsule plus 48 dp round button, 16 dp side margin, 8 dp top, 6 dp bottom, black background).

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Navigation bar on the terminal backdrop: back, centred terminal name (headline, one line), long press renames | `TerminalTopBar`: `TopAppBar` on `backdrop`, system back, title with `combinedClickable` long press to `RenameDialog` |
| 2 | Trailing cross: "End <name>", opens the end prompt | `TerminalTopBar` action `AppIcons.close`, `requestClose` |
| 3 | Files toggle (browse the folder of the terminal) | Not built: the Android file browser lives on the Files page, not inside a shell |
| 4 | Keyboard accessory "Done" | The hide keyboard key inside the capsule (row 17) serves it; Android has no accessory bar |
| 5 | Tab strip: 8 pt leading, 2 pt between tabs, hairline beneath, scrolls and centres the selection | `TerminalTabStrip`: horizontally scrolling `Row`, `animateScrollTo` on selection |
| 6 | Tab: 14 pt mark, monospaced 12.5 name (semibold when selected), 22 by 32 cross, 32 pt tall, 88 to 190 wide | `TerminalTab` chip composable with the same sizes |
| 7 | Tab mark: spinner while starting, lock or question in blue for attention, warning in red for failed, terminal glyph grey, dimmed when stopped | `TerminalMark` from `TerminalMarkKind` |
| 8 | Name colour: state tint wins, stopped is 30 percent ink, selected ink, else secondary | `terminalNameColour` |
| 9 | Selected tab: 2 pt ink capsule under it (never blue) | `TerminalTab` underline |
| 10 | Tap selects, double tap renames, context menu Rename and End | `combinedClickable` (click, double click, long click) and a `PeeringMenu` with Rename, Copy screen, End |
| 11 | Cross on each tab asks to end that tab | `TerminalTab` cross to `requestClose` |
| 12 | Tab strip accessory is empty (a shell is made on the hub) | A trailing "+" button, pinned outside the scroller: Android has no separate terminal hub, so this is where a shell is made |
| 13 | Output while starting: blue prompt glyph, blinking ink caret, "Starting login shell" with cycling dots, monospaced 13, secondary | `TerminalStarting` with a ticking caret and dots |
| 14 | Output log: monospaced, size from the Text size setting, 12 pt padding, tap focuses the input, size reported to the computer | `TerminalCanvas` with `fontSize`, tap focuses the command field, `onGrid` unchanged |
| 15 | Stopped without output: "Nothing was printed." | `TerminalStarting` is not shown, the canvas shows `terminal_nothing_printed` |
| 16 | History strip (only when there is history and it is toggled): clock glyph, monospaced capsules, tap fills the field | `TerminalHistoryStrip`, history kept for the session in `CommandHistory` |
| 17 | Deck, one row: ellipsis (36 by 44), esc, tab, ctrl-C (38 by 44), arrows left up down right as one joined group | `TerminalDeck`, keys from `TerminalKeySpecs.deck` |
| 18 | Ellipsis opens a sheet: Quick commands, Move the cursor, Delete, Shell and programs, Pages and ends, Text size | `TerminalAllKeys` in a `PeeringSheet` |
| 19 | Quick commands: outlined chips, tap runs, long press deletes, dashed Add or Edit chip | `QuickCommandsGrid`, `PeeringMenu` for delete, `QuickCommandEditor` sheet |
| 20 | Key groups with word labels (Word left, Start of line, Backspace, ...) | `TerminalKeySpecs.groups`, same bytes |
| 21 | Text size: segmented Tiny, Small, Default, Large | `SingleChoiceSegmentedButtonRow`, `TerminalTextSize`, kept in preferences |
| 22 | Input capsule: optional history clock, command field (monospaced, "Type a command" or "Process exited"), hide keyboard key while focused | `TerminalCommandBar` |
| 23 | Send button: round, return glyph when empty (sends Return), arrow up when not (sends the line) | `TerminalSendButton` |
| 24 | End prompt: "End <name>?", detail, "Keep it" and "End". An empty stopped shell closes without asking | `PeeringAlert`, `requestClose` |
| 25 | Rename alert with a Name field, Cancel and Save | `RenameDialog` |
| 26 | No terminals left: empty state "No terminals yet" with the hub copy | `TerminalEmpty` with a "New terminal" button |
| 27 | Terminal that was closed elsewhere: the screen moves to another tab or leaves | `TerminalSessions` already selects a neighbour |
| 28 | First run tour tips | Not built: Android has no tour system |
| 29 | Paste | The command field takes the system paste; the long press menu also has Copy screen because the canvas has no text selection |
