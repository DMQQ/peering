# Localization audit: apple/ changes since be87fd01

Rule being enforced: every user-visible string is internationalized in all ten shipped
languages (en source; de, es, fr, it, ja, ko, pt-BR, ru, zh-Hans).

Scope: `git diff be87fd01..HEAD -- apple` (260 files), covering the iPhone app, both widget
extensions, the Mac host and the `MacCastKit`, `RemoteCore` and `SSHCore` packages. Two other agents
own the RemoteCore sentences `pinsUnreadable`, `handshakeTimedOut` and the relay `timedOut`, and
the capture-recovery notice code mapping; nothing here touches them.

## How it was checked

- Every added line in the diff, and then every touched Swift file in full, was scanned for string
  literals reaching `Text`, `Label`, `Button`, `Toggle`, `Section`, `TextField`, `.alert`,
  `.confirmationDialog`, `.help`, accessibility modifiers, `String(localized:)` and for literals
  handed to helper parameters typed `String` (`title:`, `message:`, `help:`, `actionTitle:`),
  which SwiftUI shows verbatim.
- Each literal was matched against the catalog of its own target, with interpolations normalised
  to `%@` or `%lld`.
- A new script, `apple/Tools/check-localization.py`, now checks every catalog (see below). It is
  also a step in `apple/Tools/check.sh`.

## Counts

Keys in each catalog. "Added" is relative to HEAD before this audit; every added key carries all
nine translations in state `translated`.

| Catalog | be87fd01 | before audit | now | added by audit |
| --- | --- | --- | --- | --- |
| MacCast/Localizable.xcstrings | 1615 | 1632 | 1732 | 100 |
| MacCastHost/Localizable.xcstrings | 276 | 286 | 299 | 13 |
| MacCastWidget/Localizable.xcstrings | 46 | 46 | 47 | 1 |
| MacCastHostWidget/Localizable.xcstrings | 13 | 13 | 13 | 0 |
| MacCast/AppShortcuts.xcstrings | 9 | 9 | 9 | 0 |
| MacCast/InfoPlist.xcstrings | 5 | 5 | 5 | 0 |
| MacCastHost/InfoPlist.xcstrings | 8 | 8 | 8 | 0 |

The 23 keys the diff itself added to the phone and host catalogs (upload, shell and Keychain
alerts, transfer failures, capture recovery) were already complete in all ten languages with
matching placeholders. The gaps were elsewhere.

## Gaps found and fixed

Missing catalog entries (the string was in code, so every language showed English):

- Phone: "Connection keeps dropping. Check that the computer is awake and on a good network, then
  try again." (the verdict after repeated drops).
- Widget: "Coding agent" (the fallback name on an agent Live Activity card).
- Host: the six Live Activity alert texts (`An agent needs you` and five more), "A test
  notification from your Mac.", and the terminal push texts, which were plain English.
- "No" (the notification action button) had no translations at all and showed "No" everywhere.

Plain English that never went through localization:

- Terminal and command-finished pushes built on the Mac (`Terminal needs you`, `Terminal
  finished`, the waiting and finished sentences). They now use `String(localized:)`.
- "... finished after 4s": the phone and the host glued an English suffix ("after 4s") onto a
  translated sentence. `TerminalCommandFinishDetector.durationSuffix` is replaced by
  `spokenDuration(_:locale:)`, which writes the duration with `Duration.UnitsFormatStyle` ("4秒",
  "2 Min. 5 s"), with tests. The old key `%@ finished%@.` is now unreferenced.
- Session history (Activity tab): "received" appended to a byte count, the "1m 6s" duration
  helpers, and the copied log lines `Path:`, `Connected:`, `Video received:` and the empty-log
  sentence.
- Video stats overlay: "123 frames".
- Settings: `.ready` showed the literal "Connected"; the failure line now maps wire text.
- Host menu bar: the "Report an issue" tooltip went to a `String` parameter and was never
  looked up.
- Phone: file browser "Reading…" and "Try again" (String parameters), the clipboard panel "Send",
  the recent-connections "Connected" label, and the Face ID prompt's Cancel button
  (`LAContext.localizedCancelTitle`).

A real logic bug found on the way: `HostPickerView+HomeCards` matched the English failure text
from the relay and RemoteCore against `String(localized:)` values for "not currently registered
with the relay", "a different mac answered", "host speaks v" and "client speaks v". In any language
but English the translated needle never matched, so those failures fell through to the generic
card. They are plain English literals now, with a comment saying why.

Catalog hygiene:

- 57 entries with no translations at all (symbols, `PEERING`, `LAN`, `P2P`, `9:41`, `docker ps`,
  PiP diagnostic words, `CFBundleName`) are marked `shouldTranslate: false`, so a missing
  translation can no longer hide among them.
- 27 AppShortcuts phrases were `needs_review` although their text is correct; set to `translated`.
- Catalog files keep their existing key order and formatting, so diffs stay small.

## Wire text

English sentences the Mac (or a library) sends and the phone shows. The phone now runs these
through `HostWireText.localized(_:)` (`apple/MacCast/Session/HostWireText*.swift`) at the point of
display: exact sentences by `switch`, sentences with a path, name or number by
`SentenceTemplate` (`MacCastKit`, tested). No protocol change: an unknown sentence, or one from a
newer Mac, is shown unchanged. Matching is on the English, so a Mac whose own language is not
English that already localized a sentence is shown as the Mac wrote it.

Mapped (about 100 sentences, all in the phone catalog):

| Where it arrives | Source | Sentences |
| --- | --- | --- |
| Pairing refusal (`PairResult.reason`) | `HostSession+Handshake.swift` | codes did not match, code not accepted, declined on the Mac, another device pairing, too many attempts, could not save the pairing |
| Connection failure (`.failed` phase) | `RemoteCore` (`NetworkFailureText`, `ClientSession+*`) | the nine `NetworkFailureText` sentences, "stopped answering", "video channel did not come back", "The Mac reported an error", "Hosting stopped on this Mac", busy, pin mismatch, no pin on file, different Mac answered (these three carry an id) |
| Terminal `.failed`, `.attention` | `TerminalSessionManager*.swift` | create, limit, too large, no longer running, write, login shell, waiting for a password or confirmation |
| Agent `.failed`, browse | `AgentSessionManager*.swift` | prompt too long, cannot continue, mode, no longer here, cannot chat, folder, limit, could not start, not installed or PATH, history, import |
| File transfer and browsing | `TerminalSessionManager+FileTransfer/Download/FileBrowsing/FileChanges.swift`, `DirectoryListing.swift` | about 35 sentences, plus the log notes "created folder X", "renamed A to B", "moved X to the Trash" |
| Remote notice | `HostModel+Sessions.swift`, `HostModel+Events.swift` | locked, display disconnected, screen asleep, Privacy Mode could not darken or cover |
| SSH browse | `SSHCore` | "The server did not answer in time." |

Wire text that is not mapped, with the reason:

- `ErrorPayload.message` for any code other than the ones above and the capture-recovery notice
  (owned by another agent).
- `RemoteCore` handshake internals: "The Mac's hello could not be read.", the commitment and reveal
  sentences, "Expected X from the Mac, got Y.", the protocol mismatch sentence, "This device's
  identity could not be loaded: ...". Developer-grade, rare.
- Relay messages: "The relay refused the session: ...", "That Mac is not currently registered with
  the relay." (matched in English by the failure card, which has its own localized replacement),
  `RelayProtocolError`.
- Agent git and changes text: `AgentGitRefusal.text` (MacCastKit), `AgentGitActions` messages,
  `AgentChangesReader` failures other than the not-a-repository pair. Pre-existing, not in the diff.
- `PerTurnAdapter` and `ClaudeCodeAdapter` composed messages (`\(message)\n\(tail)`) and the
  "A line from the agent was too long to read and was skipped." transcript notice.
- Mosaic placeholder text drawn into the video by the Mac ("This window has closed", "Nothing to
  show"). It is part of the picture, so it follows the Mac's language, and it is English now.
- SSHCore sentences other than the timeout: the file service messages in `SSHFileService*.swift`
  and `SSHSession.swift` (about 20, none changed in the diff).

Texts that reach the phone as operating system notifications cannot be mapped there. They are
written on the Mac, so they now follow the Mac's language: terminal pushes, the Live Activity
alerts (`LiveActivityPushBuilder.alertText`, passed as plain strings to the relay) and the test push.
A phone and Mac set to different languages will see the Mac's. Fixing that needs a locale or a
`loc-key` on the registration or the relay payload, which is a protocol change, so it is left.
`AgentNotificationText` (agent approval and finish pushes: "Claude Code asks", "Needs your
approval.", "The turn finished.") and `AgentTurnDigest` are still English only; they are pure
functions in `MacCastKit` with English assertions in their tests, not part of this diff.

## What remains

1. The Mac host Activity feed (`HostModel.record(...)`, about 40 call sites in `HostModel+Events`,
   `+Lifecycle`, `+Sessions`, `RelayHostRegistration`, `HostServer`, `VideoCoordinator`). It is shown in
   the host window and also copied to the unified log and the diagnostics report. It was English
   before this range and is left English: translating it would make support reports unreadable.
   Decide whether it counts as user-visible.
2. `HostSession.clientName = "Unknown device"` before the hello arrives.
3. The strings in "Wire text that is not mapped" above.
4. `SessionPiP.lastAttempt` and `lastRefusal` (four `String(localized:)` words and two English
   multi-line strings) are written and never displayed; they are marked do-not-translate in the
   catalog. Delete them or show them.
5. The `Stop ${applicationName}` phrase in the Disconnect App Shortcut set exists in English only;
   other languages have one phrase per shortcut.
6. Quotation marks around a command in the terminal-finished sentence are always curly English
   quotes (`“ls”`), also in German or Japanese.

## Stale and unreferenced entries (reported, not deleted)

`check-localization.py --stale` lists them.

| Catalog | stale |
| --- | --- |
| MacCast/Localizable.xcstrings | 269 |
| MacCastHost/Localizable.xcstrings | 5 |
| MacCast/AppShortcuts.xcstrings | 5 |

Do not delete these blindly. Xcode does not extract strings from Swift packages, so every
`String(localized:)` in `MacCastKit` (session notifications such as "Connected to %@", the relay
quality labels, tour copy) is flagged stale although it is in use. In the phone catalog 50 of the
269 stale keys still appear as literals in the sources. Newly orphaned by this audit:
`%@ finished%@.` and `%lld seconds`.

## The check script

`apple/Tools/check-localization.py` (python3, standard library only, about 0.3 seconds). It fails
on invalid JSON, duplicate keys, a key missing any of the nine target languages, a state other than
`translated`, an empty value, and placeholders (`%@`, `%lld`, `%1$@` and the rest) that differ from
the source. Plural and device variations are checked per variation. Entries with
`shouldTranslate: false` and the empty key are skipped. It accepts catalog paths as arguments and
exits non-zero on any problem.

## For a native speaker to review

All new text was written by the same model that wrote this audit, reusing the terms already in the
catalogs: relay (Relay, relay, relais, relay, リレー, 릴레이, relay, релей, 中继), pairing (Kopplung,
emparejamiento, association, abbinamento, ペアリング, 페어링, pareamento, связывание, 配对), session
(Sitzung, sesión, session, sessione, セッション, 세션, sessão, сеанс, 会话), shell (Shell, shell,
shell, shell, シェル, 셸, shell, оболочка, shell), Keychain (Schlüsselbund, llavero, trousseau,
portachiavi, キーチェーン, 키체인, Chaveiro, связка ключей, 钥匙串).

Least sure, in order:

1. **Russian**: "ход" for an agent turn, "связывание" for pairing, "Хостинг на этом Mac остановлен",
   and the count sentence "Дисплеев этого Mac, которые всё ещё видны: %lld" (written to avoid plural
   agreement; no plural variations were added anywhere).
2. **Korean**: "이(가)" and "을(를)" particles in sentences with a variable (`Terminal “%@”이(가)
   ...`) read as placeholders; "차례" for turn; "호스팅".
3. **Japanese**: register of the notification titles ("エージェントがあなたを必要としています"),
   "ホスト" for hosting, "ターン" for turn.
4. **Chinese (Simplified)**: "智能体" for agent (matches the existing catalog), "托管" for hosting,
   "这是这台 Mac 上过大的范围，无法删除。" for "That is too much of this Mac to delete."
5. **Italian**: "stop" for sleep (Apple's own Italian term) in the connection sentences.
6. **French**: "mode confidentiel" for Privacy Mode and "épinglée" for a pinned key.
7. German, Spanish and Portuguese: lowest risk; "Durchlauf" for turn (existing catalog term) and
   "vez" in pt-BR are the only unusual picks.

Strings worth a native read because the meaning is easy to flip:

- "Something at this address is not the Mac you paired with (%@)..." and "This iPhone has no
  pairing on file for that Mac (%@)..." (the security explanation on an identity change).
- "That is too much of this Mac to delete."
- "That transfer was sent in pieces this Mac cannot accept."
- "... finished after %@." (the word order around the duration in ja, ko, ru and zh-Hans).
- The three `created folder`, `created file` and `renamed A to B` log notes (lowercase fragments).
