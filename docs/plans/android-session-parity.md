# Android session parity checklist

Source: `apple/Peering/Remote/RemoteScreen*.swift`, `RailButtons`, `ScrollWheelView`, `JoystickView`, `SourcesPanel*`, `ClipboardPanel`, `SettingsPanel`, `Connection/SettingsTab*`, `HostPickerView+ActivityTab`, `Onboarding/FAQView`, and `marketing/appstore/raw/en/02-session.png`, `03-keyboard.png`, `04-shortcuts.png`, `05-settings.png`.

The phone's layout is the blueprint. Android adaptations are limited to the Material 3 `NavigationBar`, ripples, system back and insets, Material menus, dialogs and sheet behaviour, switch and text field styling. Wording says "computer" for "Mac".

## 1. Session screen, portrait

Edge inset 8 dp, bottom inset 22 dp, gap 8 dp. Chrome is drawn over the picture on a tonal surface (`containerHigh`) with no outline (`sessionSurface`, `LocalBorderless`).

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Picture fills the screen, pinch zoom, two finger pan, tap and drag act on the Mac | `RemoteCanvas` (unchanged) |
| 2 | Status bar row, top: lock circle (48), status pill, terminal circle (48), 6 dp inset | `SessionStatusBar` |
| 2a | Lock circle: lock glyph, tap locks the Mac, long press menu "Lock screen" and "Dim displays" | `LockButton`, `LockScreen` and `SetPrivacyMode` commands, `PeeringMenu` |
| 2b | Collapsed pill, 56 dp: green dot (amber while reconnecting, red when not streaming), computer name, below it the source title (or "Reconnecting...") and the route chip (LAN, RELAY, DIRECT), chevron down at the end | `StatusPill` collapsed, `RouteChip` |
| 2c | Tap opens the expanded pill: dot, name, route chip, then labelled rows of equal chips | `StatusPill` expanded, `StatusRows` |
| 2d | Row Stream: Sound, Screenshot | Sound has no Android audio path and Screenshot has no capture hook: not shown (see "Not matched") |
| 2e | Row View: Fill/Fit chip, zoom percent chip (when zoomed, resets), Immersive | `fillChip`, `zoomChip`, Immersive hides the chrome for a reveal handle |
| 2f | Row Computer: Lock, Darken or Restore | `LockScreen`, `SetPrivacyMode` |
| 2g | Row Session: Connect (leave the screen, session continues), Terminal | `onStepAway`, `onOpenTerminal` |
| 2h | Row End: Quit (filled danger) | opens the leave dialog |
| 2i | Terminal circle (48): opens the terminal hub | `TerminalButton`, opens `SessionHub`: one full-height panel with a segmented Agents, Terminals, Files switcher (`HubTabBar`, `HubTabsPresenter`), the last tab remembered |
| 3 | Floating panel above the dock (shortcuts, clipboard, apps, settings), one at a time, glass, rounded 22 | `SessionPanelHost` |
| 4 | Scroll wheel, left, 54 x 120: up chevron, ridged rim, down chevron; drag rolls notches, flick coasts, chevrons step one notch; zoom gauge in Observe | `ScrollWheel`, `ScrollWheelState`, `WheelSpin` |
| 5 | Pointer row, centred: Back key (46), joystick disc (100), Enter key (60), each captioned | `PointerRow`, `QuickKey`, `Joystick` |
| 5a | Joystick: drag nudges the pointer at 60 Hz, tap left click, hold right click, double tap steps speed with a badge | `Joystick`, `JoystickMove`, `JoystickSpeed` |
| 6 | Dock card, 5 slots per page plus a fixed chevron toggle, glass, rounded; page dots under it | `SessionDock`, `DockPages` |
| 6a | Pages (collapsed): Apps, Keyboard, Clipboard, Shortcuts, Tab / arrows and Delete / Esc, Mode, Settings / edits Copy, Paste, Undo, Cut, Quit | `DockControl`, `DockPages.of` |
| 6b | Chevron expands to 3 rows per page | `SessionDock` |
| 6c | Page dots, tap jumps | `DockPageDots` |
| 7 | Keyboard mode: dock and pointer row give way to the input bar | `KeyboardBar` |

## 2. Session screen, landscape

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Leading rail (capsule 54 wide): Keyboard, Shortcuts, Clipboard, Mode, Apps, Settings | `ControlRail` |
| 2 | Trailing rail: quick actions (Copy, Paste, Undo, Cut, Quit), Esc, Tab, arrows, Delete | `ControlRail` |
| 3 | Status bar, centred, capped between the rails | `SessionStatusBar` |
| 4 | Bottom row: wheel left, pointer column right (Enter above Back and joystick) | `PointerColumn` |

## 3. Keyboard accessory (03-keyboard.png)

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Glass card above the system keyboard, rounded 20 | `KeyboardBar` |
| 2 | "Typing..." field showing the typed text (head truncated) | `TypedPreview`, `KeyboardPresenter.typedPreview` |
| 3 | Row: filled hide-keyboard button, Cmd, Shift, Option, Control latches, Esc, Tab, flexible space, Enter | `KeyboardKeyRow`, `StickyModifiers` |
| 4 | Row: left, up, down, right, delete | `ArrowStrip` |

## 4. Shortcuts panel (04-shortcuts.png)

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Segmented picker: the running application's name (when it has a profile), Shortcuts, F1-F12 | `ShortcutSets`, `SingleChoiceSegmentedButtonRow` |
| 2 | Application set: grid of key chips with the chord (Cmd+Shift+P) | `ApplicationProfiles`, `KeyChipGrid` |
| 3 | Shortcuts set: 17 built in chips, then an edit chip | `Macros`, `MacroStore` |
| 4 | F1-F12 set: fn latch chip, then F1 to F12 with the printed action icon | `FunctionKeyGrid` |
| 5 | Modifier row: Cmd, Shift, Option, Control latches, equal width | `ModifierRow` |
| 6 | Bottom: Delete and Enter at the leading side, arrow cluster at the trailing side | `ArrowCluster` |
| 7 | Macro editor: label, key menu, four modifier switches, preview, Add | `MacroEditorSheet` |

## 5. Clipboard panel

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Phone row: tile, "Phone", detail ("Nothing copied", text, "Image copied"), actions Send, Paste on computer | `ClipboardPanel`, `PushClipboard`, then Cmd+V |
| 2 | Computer row: tile, "Computer", detail, action Copy to phone | `RequestClipboard` on open, the reply is decoded into `SessionUiState.hostClipboard`, Copy to phone writes the Android clipboard |
| 3 | History row with count and chevron, then history list with Clear and per row copy or send | Not matched: no history is kept on Android |

## 6. Apps panel (sources picker)

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Search field | `SourcesSearchField` |
| 2 | Mosaic entry | Not matched: the mosaic source has no composer on Android |
| 3 | Virtual displays | Not matched: the host command exists, the Android client has no flow for it |
| 4 | Screens section label, a row of display tiles with thumbnail and caption | `SourcesPanel`, `SourceTile` |
| 5 | One section per application: icon, name, window count (tap picks the whole application), a row of window tiles, a dashed "New window" tile | `ApplicationSection`, `SourceGrouping` |
| 6 | Installed on your computer: icon grid, tap launches, footnote | `InstalledGrid`, `LaunchApplication` |
| 7 | Empty state when no list has arrived | `SourcesPanel` |

## 7. Settings panel (session)

Sections in order, each a section label with rows: Session (info rows, Lock button), Recent activity, Stream (Display app or window row, quality, sound, codec note), Panels (Close after selecting), Picture, Privacy (Allow the relay, Darken the computer's displays), Keyboard (mode, open for text fields), Macros, Paired computers, This device. Android: `SessionSettingsPanel` with Session, Stream (Apps row, quality segmented control Automatic and Manual with level, codec row), Panels, Privacy (relay and darken), Keyboard (open for text fields), Macros, This device. Rows for sound, picture in picture and recent activity have no Android source and are left out.

## 8. Sessions tab

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Serif title "Sessions", detail "Recent sessions and relay use." | `TabScreen` |
| 2 | Relay card: label, "Free relay time" with remaining, meter bar, "last 24 hours", footnote, upgrade button when low | `RelayCard` |
| 3 | Recent connections card: label, summary (sessions, connected, video), rows with tile, name, detail, time, chevron | `RecentConnectionsCard`, `SessionHistory` |
| 4 | Row opens a detail: Connection card and Session log card | `SessionDetail` |
| 5 | The tab is always the history; a live session is opened from its row in Connect | `SessionTab`, `FeatureWiring.connectOrResume` |

## 9. Settings tab

Title "Settings", detail, search field, then cards in order: This device (device name), Session controls (Interaction, Picture, Keyboard, Close panels after selecting; "Open keyboard for text fields" is left out because the computer never says when a text field is focused), Stream quality, Remote access (Allow relay connections, Upgrade), Security and privacy (biometric lock), Trusted computers, Device identity, More (Get Peering for the computer, Show introduction again, Report an issue), Legal. Picture in Picture, Home Screen widget, Live Activity, Notifications and Developer are iOS only and are not drawn.

## 10. FAQ tab

Title "FAQ", detail, one outlined card per section with a label, rows with the question and a chevron that turns, answer opens in place, hairline between rows. Sections: Getting started, Privacy, What moves between devices, Plans, Security and troubleshooting, Known gaps, with the iPhone's questions reworded for this app.

## Not matched, and why

- Sound and Screenshot chips, the Sound switch: no Android audio player or capture hook exists in the session core.
- Mosaic, desktops (Spaces) tiles, virtual displays: no Android client flow; the wire commands are unused.
- Clipboard history: nothing keeps it on Android.
- Video byte counts in the Sessions summary and rows: the session record has none, so the summary shows relay time instead.
- Picture in Picture, widget, Live Activity, notification rows: iOS features.
- Landscape hint card and tour anchors: no Android tour.
