# Android Files: gaps against the iPhone app

Source of truth for the iPhone behaviour: `apple/MacCast/Files/*`, `apple/MacCast/Terminal/MacSession+File*.swift`,
`apple/RemoteCore` (`RemoteFileKind`, `RemoteFileName`, `FileDownloadLimits`), and the file cases of `TerminalWire.swift`.

Capability: the host declares one flag, `supportsFileBrowser`. It gates the scope, listing, preview, range reads, archives,
writes and changes alike (there is no separate write flag). Without it the Android Files entry shows the unavailable page.

| Capability on iPhone | Android before | Plan |
| --- | --- | --- |
| Breadcrumb path bar, tap a crumb | Present (inline row) | Move into the top app bar area, scroll to the end |
| Up one level | Present (text button) | Back arrow walks up folders before leaving the screen |
| Sort | Name, size, modified chips | Keep, move into the app bar menu |
| Hidden-file filter | Chip | Keep, menu item |
| Search this folder | Missing | Add (local filter, cleared per folder) |
| Row: type icon, size, date, permissions | Folder or file glyph, size only | Icon per file kind, `permissions, size, date` line |
| Pull to refresh | Missing | Add |
| Loading, empty, error states | Basic text | Add permission denied, not found, host offline, wait hint |
| Preview: text | Plain monospace lines, 1 MiB cap | Add wrap toggle, line numbers kept out, truncation note |
| Preview: image | Decoded when complete | Keep, tell when a picture is over the cap |
| Preview: markdown | Missing | Render headings, lists, code, quotes |
| Preview: svg, pdf, video | Missing | Not drawn on Android yet: offer download and share |
| Large-file range reads | Download only (512 MiB cap) | Keep; preview caps 1 MiB text, 8 MiB drawn |
| Download to the phone | Preview only, SAF save | Also from the list (file or folder zip), progress and cancel |
| Share the file | Missing | Share intent from the preview |
| Upload files | Missing | Add: system picker, chunked write, progress, cancel |
| Upload photos | Missing | Same picker (it lists the photo library) |
| Upload folder | Missing | Not on Android (no folder picker with contents) |
| New folder, new file | Missing | Add (FAB menu, free name suggestion) |
| Rename | Missing | Add |
| Delete with confirmation | Missing | Add, recursive wording for a non-empty folder, multi-select |
| Edit and save a text file | Missing | Not in this round |
| Run an executable | Not on iPhone hub either (`onRun` nil) | None |
| Remember the last folder per computer | Missing | Not in this round |
| Floor at the user's home | Missing | Not in this round |
| Folder picker for the Agents hub | Agents has its own over `AgentEvent` | Reusable `FolderPickerPresenter` on the file browser |
| Change failures above the list | Missing | Banner/snackbar, list stays |

Android specifics: Material 3 (top app bar, FAB menu, contextual selection bar, bottom sheet free), "computer" not "Mac",
and virtual POSIX paths for Windows hosts (`/C:/Users/me`) through `FilePath`.

Limits chosen for the phone: uploads are capped at 64 MiB because the outgoing queue holds the whole file as frames
(the host accepts 2 GiB). Downloads stay at the shared 512 MiB cap.

## Result

Closed: path bar, search, sort, hidden filter, type icons with mode, size and date, pull to refresh, loading, empty,
permission, not found and offline states, text (wrap toggle, line numbers for code), image and markdown preview, download
of files and folder zips with progress and cancel, share, upload with progress and cancel, new folder and file, rename,
delete with confirmation, multi-select, and the reusable FolderPicker (FolderPickerPresenter over the file browser).

Still open: edit and save, remembered folder, home floor, svg, pdf and video preview, folder upload, and a swap of the
Agents hub own picker for FolderPicker (that feature belongs to another change).
