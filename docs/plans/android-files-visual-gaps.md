# Android Files tab: visual gaps against the iPhone

Source of truth: `apple/MacCast/Files/` (FileBrowserPanel, FileBrowserPanel+List, FileBrowserPanel+Header, FileEntryRow,
FolderBrowserBar, MacFilesScreen, FilePreviewPanel+Toolbar) and `apple/MacCast/Design/SharedControls.swift`.
The hub embeds the browser with `embedded: true` and `showsBreadcrumbs: false`, so the Files tab has no heading and no
breadcrumbs: the hub switcher, the list, and one bottom bar.

Status: FIXED, KEPT (deliberate) or OPEN.

| Element | iPhone (file, value) | Android before | Status |
| --- | --- | --- | --- |
| Heading with folder name, search icon, menu | None when embedded (`MacFilesScreen.PushedFolderChrome` is off) | Serif top bar "dmq", search icon, three-dot menu | FIXED: no top bar in the hub; `FolderTopBar` remains only for a non-hosted page |
| Breadcrumb row | None when embedded (`showsBreadcrumbs: false`); location shown in the bottom bar | "/ > Users > dmq" row | FIXED: removed from the list screen (the folder picker keeps its own) |
| Location line | `FolderBrowserBar.location`: folder glyph 11 medium + path monospaced 12, `.secondary`, head truncation, 4 horizontal inset | none | FIXED: `LocationLine`, `headTruncated` (36 chars) |
| Bottom action | Row of `chrome` circles 48x48 glass, search capsule between (`FileBrowserPanel+Header.bottomBar`) | White round "+" FAB | FIXED: `FilesBottomBar`: new circle left, capsule, send circle right |
| Bar insets | `.padding(.horizontal 16, .top 8, .bottom 6)`, row spacing 8 | n/a | FIXED: same values, plus IME and navigation bar padding |
| Search | Always-visible capsule, `InputBar.height` 48, radius 24, horizontal pad 14, magnifier 14 medium, field 16, clear xmark 16 tertiary | Search icon opening a top-bar field | FIXED: capsule in the bottom bar, live filtering, Back clears the query first |
| Hidden toggle | Eye / eye.slash inside the capsule, 28x36, accent when shown, secondary otherwise | Item in the three-dot menu | FIXED: eye inside the capsule (36 wide) |
| Sort | None | Menu in the three-dot menu | KEPT: long press on the eye opens order and Refresh (Android feature; the iPhone has no sort) |
| New item | Menu on the plus circle: New Folder, New File | FAB menu with an upload item too | FIXED: plus circle menu has New folder and New file; upload is its own circle |
| Send | Circle with `arrow.up.to.line` opening a Files / Photos menu | Third item in the FAB menu | PARTLY: own circle, opens the system document picker (which includes photos); no two-way menu |
| Surface of circles and capsule | `glassSurface` (system material) | n/a | KEPT: Android has no glass; uses `sessionSurface` tonal fill, as the Terminals dock does |
| Row layout | `FileEntryRow`: HStack spacing 11, leading 16, trailing 16, vertical 8, chevron right at the end | `ListItem` with 40dp circle, no chevron | FIXED: same paddings (16/16/8), spacing 11, chevron `caption.weight(.semibold)` tertiary, 16dp |
| Icon tile | `Controls.icon`: 28x28, radius 8 continuous, fill tint at 0.14, glyph 13 semibold | 40dp circle at 0.12 | FIXED: 28dp, radius 8 (`FileTileShape`), 0.14, glyph 15dp |
| Name | `.subheadline.weight(.medium)` (15), ink, 1 line, middle truncation | titleMedium-ish ListItem headline | FIXED: `PeeringText.subheadlineMedium`; ellipsis at the end (Compose has no stable middle ellipsis) |
| Subtitle content | `permissions` (monospaced 11) + " · size · date"; size `byteCount(.file)` (decimal), "Zero bytes" for 0, folders show their own size, symlink says "Symbolic link"; no mode: a word (Folder / File / Symbolic link) | mode, size (folders none, binary units "1.0 KB"), date | FIXED: `FileRowDetail`, `FileSize` (1000 steps, bytes / 0 decimals KB / 1 MB / 2 GB) |
| Subtitle font | `.caption` (12), `.secondary` | bodyMedium muted | FIXED: `PeeringText.caption`, muted |
| Date format | `date: .abbreviated` ("Apr 8, 2026") | same | MATCH |
| Row height | 8 + 20 + 2 + 16 + 8 = 54 | about 72 | FIXED (54) |
| Grouping | Flat list, no card, no fill | Flat list | MATCH |
| Dividers | `Controls.divider`: `Divider().overlay(white 0.07)`, full width, between rows | none | FIXED: hairline at ink 0.07 between rows |
| Up row | `upRow`: arrow.up.left tile, ".." monospaced 15 medium, "Up one level" caption, no chevron | none (back via system Back) | FIXED: `UpRow` shown when the folder has a parent |
| Press feel | `Button(.plain)`: content dims while held | Ripple | FIXED: alpha to 0.6 over 120 ms read in `graphicsLayer`, no ripple, no infinite animation |
| Selection mode | None (context menu: download, upload here, rename, delete, run) | Long press selects, contextual top bar | KEPT: Android's multi-select is an addition; the bar sits under the hub switcher |
| Truncated notice | caption, tertiary, 16 x 12 padding after a divider | bodySmall faint, padding 16 | FIXED: padding 16 x 12, divider above |
| Empty / error / loading | Centered 22 light glyph, subheadline secondary, caption tertiary detail, accent "Try again" | `EmptyState`, tonal retry button | OPEN: kept the shared `EmptyState` component; copy matches in intent but sizes differ slightly |
| Change failure banner | Caution tint at 0.12, caption, 16 x 8 | Banner | OPEN: not compared pixel for pixel |
| Pull to refresh | `.refreshable` | `PullToRefreshBox` | MATCH |
| Run button on executables | play.fill circle 32, accent 0.14 | none | OPEN: Android never runs files from the browser |
| Preview top bar | Inline title (file name), trailing wrap toggle; bottom bar with share, status line (size and relative date), pencil | Close, title, wrap, share, download | OPEN: Android keeps one top bar; the status line and the editor are not built |
| Bottom backdrop | `reviewBottomBackdrop`: rows scroll under a fade | Solid bar below the list | OPEN: rows do not scroll under the bar |
| Context menu | Long-press menu per row | Selection mode | OPEN: see Selection mode |
