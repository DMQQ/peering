# Session panels and chrome: iPhone against Android

Reference: apple/MacCast/Remote and marketing/appstore/raw/en/02-session, 03-keyboard, 04-shortcuts. Status: same (already matched), fixed (changed in this round), open (still different).

## Status pill
| iPhone element | Value (Swift) | Android | Status |
| --- | --- | --- | --- |
| Two lines: name (caption semibold), then source title (caption2, secondary) and route chip | RemoteScreen+Status.swift 160-210 | CollapsedPill shows both; StatusUi.sourceTitle comes from the catalogue row of the active source (RemoteStates.kt) | same (the title was already wired) |
| Reconnecting replaces the title | amber "Reconnecting..." | same | same |
| Title ellipsised, chip keeps its width | lineLimit 1, layoutPriority 0 | weight(1f, fill = false) | same |
| Height 56, padding 16 / 20 | Status.swift 200-215 | pillHeight 56, same padding | same |
| Corner radii | 30 collapsed, 26 expanded (Theme.swift) | was 28 for both | fixed (interpolated, clamped to half height) |
| Width cap | statusBarMaxWidth 460 | 460 in landscape | same |
| Mosaic title "N windows" | activeSourceTitle | sourceLine shows the plural "N windows" while a mosaic is up | fixed |

## Dock
| Element | Value | Android | Status |
| --- | --- | --- | --- |
| Width | dockWidthFraction 0.9 | was 0.94 | fixed |
| Collapsed card radius | dockCollapsedHeight / 2 = 35 | was 20 | fixed |
| Expanded card radius | 28 | 28 | same |
| Toggle hit height | buttonHeight 62 | was 48 | fixed |
| Slots per page | fixed 5 | 3 to 5 by width, slot minimum now 52 dp so every phone from 360 dp gets 5 | fixed (was 64, giving 4) |
| Open panel's item becomes accent capsule with label in ink, label semibold | RailButtonLabel | RailButton selected for Apps, Keyboard, Clipboard, Shortcuts, Settings, Mode(observe) | same, verified in DockControls.kt |
| Standing height reserved above the dock | 204 (3 rows + paddings + dots) | 214 | fixed |
| Status height reserved for panel ceiling | 44 | 56 | fixed |
| Press feedback | scale 0.9, opacity 0.6, pressedFill | tonal ripple via heardTap | open: system behaviour |

## Shortcuts panel
| Element | Value | Android | Status |
| --- | --- | --- | --- |
| Segmented header: app profile name, Shortcuts, F1-F12 | Picker .segmented | was Material outlined SegmentedButton with check icon | fixed: track (ink 0.1, pill) with the chosen set lifted (ink 0.16), 32 dp tall |
| Key grid | adaptive min 76, spacing 8, minHeight 44, radius 9, ink 0.1 fill | radius was 12 | fixed (9) |
| Key text | 15 medium | subheadlineMedium | same |
| Modifier row | 4 equal keys, minHeight 44, spacing 8, radius 9, latched = accent | radius was 12 | fixed |
| Delete, Return 64x40, arrows 52x40, spacing 6, radius 9, arrow column up over down | ArrowCluster | radius was 12 | fixed |
| Typed preview line when keyboard open | monospaced footnote | none (keyboard bar replaces panel) | open: keyboard closes panels on Android |
| Panel radius, padding | 22, 10; max width 520 | was 20 | fixed (22) |

## Keyboard bar
| Element | Value | Android | Status |
| --- | --- | --- | --- |
| Large key | 54x42, glyph 18, radius 10 | was 48x44, 22 | fixed |
| Small key | 40x32, glyph 14, radius 10 | was 40x36, 22 | fixed |
| Modifier keys | 38x34, radius 9 | radius 12 | fixed |
| Field radius | 10, backdrop 0.55 plus 1 pt white 0.08 outline | radius 12, no outline | fixed radius; outline left out (open, intentional: fills only) |
| Landscape | padding 8, arrows move into the key row | always 12 and a third row | fixed |
| Card radius, padding | 20, 14 horizontal | same | same |

## Clipboard panel
Phone and Mac rows (28 dp icon tile ink 0.14 radius 8, title semibold, detail caption 2 lines, actions as capsules ink 0.12, prominent ink with onInk text, 1.5 s check) match. Built to match the iPhone: the History row (clock icon, count, chevron) shown when the history is not empty; the history list (back with "History", Clear with a confirmation that says the computer's clipboard is untouched, rows of up to 3 lines of text or an image thumbnail with relative time, tap copies to the phone and shows "Copied", long press offers Send to computer and Delete, the empty-state sentence, list height capped at 340 dp); newest first, de-duplicated by content (a repeat moves to the top), capped at 25, text kept across launches (100,000 bytes per entry at most) and cleared by Clear. Image clipboards both ways when the computer declared supportsClipboardImages: the phone's clipboard picture is read through ContentResolver (a PNG as it is, anything else decoded and re-encoded as PNG), refused over 8 MB with "Image too large to send (size, limit)", sent as chunked commands and pasted with Paste on computer; a picture from the computer (chunked clipboard frames, 12 MB reassembly cap) shows as "Image" and Copy to phone puts it on the clipboard through the app's FileProvider. The hello declares supportsClipboardImages = true, which is now safe because chunked clipboard frames no longer reach the picture stream's reassembler.

Differs: the iPhone records only what it pulled from the Mac. Android also records what the phone sent (text and pictures), each with a direction kept in the store; the list shows neither, as on the iPhone. Pictures in the history stay in memory for the session (at most 32 MB in total, oldest dropped first) because 25 pictures of up to 8 MB should not be written to preferences. The "Show" action is not built: reading the clipboard asks nothing on Android while the app is in front, so the phone row always shows its text. Relative times are computed when the list is drawn and do not tick.

## Apps (sources) panel
Search capsule, screens row, one section per application with window tiles, installed grid of 5 columns, 10 pt titles and 9 pt subtitles match. Open: virtual displays, desktops (Spaces) sections and the window controls on long press are not built on Android; tile minimum width 156 grid versus Android horizontal rows of 98 dp tall tiles.

## Settings panel
Section order and search follow SettingsPanel.swift. Open: Recent activity, Direct path, Video and control latency rows, sound toggle, and HEVC badge are absent from the panel; they depend on session facts Android does not publish yet.

## Mosaic
| iPhone element | Value (Swift) | Android | Status |
| --- | --- | --- | --- |
| Entry card, shown only when the host declares supportsMosaic | SourcesPanel.mosaicEntry | MosaicEntryRow, gated by RemoteUiState.supportsMosaic (a Windows host never declares it) | same |
| Multi-select picker, order of picking is tile order, 2 to 9 | SourcesPanel+Mosaic mosaicPicker | MosaicPicks, numbered badge on picked tiles, "Pick two or more" / "N picked" / "up to 9", Sources and Show mosaic buttons | same (bar sits under the search field, not pinned at the bottom) |
| Summary rows while active: Back to the mosaic (N windows), Add or remove windows | mosaicEdit | MosaicEditRows | same |
| Layout: columns by portrait or landscape, median tile aspect, canvas within 2560x1440 and even | MosaicGrid | session MosaicGrid, same arithmetic | same |
| Selection is a normal setCaptureSource with the layout inside | CaptureSource.mosaic(MosaicLayout) | CaptureSource.Mosaic(layout), capability checked by HostCapability.requiredBy | same |
| Input refused while up, Space switching still allowed | isBlockedByMosaic | RemoteCommand.isBlockedByMosaic, MosaicGate in front of the tracker | same |
| Tap on a tile selects its source | RemoteCanvas onMosaicTap | MosaicTapDetector then MosaicHit through letterbox, zoom and pan | same (no hero zoom transition) |
| Cursor glyph, joystick and wheel hidden | isShowingMosaic | ChromePolicy.cursorShown and pointerControlsShown | same |
| Rotation rebuilds the arrangement | refreshMosaicForViewport | layout keeps the shape it was asked for until the user starts it again | open |
| Hold and drag a tile to reorder, per-tile remove, tile size weights | RemoteScreen+Gestures, MosaicOverlay | not built; reorder by editing the picks | open |
| Tile outlines and labels drawn over the picture | MosaicOverlay | the host's composited picture is shown as is | open |
| Dropping tiles whose window closed, remembered arrangement per host | dropClosedMosaicTiles, MosaicArrangementStore | the host draws a card for a gone window; the arrangement lasts for the session only | open |
| Active state comes from the picture's source id | pictureMosaicLayout | the chosen source (what was asked for) | differs: Android has no per-picture source id yet |
