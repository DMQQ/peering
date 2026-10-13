# Localization audit: apple/ changes since be87fd01

Rule being enforced: every user-visible string is internationalized in all ten shipped
languages (en source; de, es, fr, it, ja, ko, pt-BR, ru, zh-Hans).

Scope: `git diff be87fd01..HEAD -- apple` (260 files), covering the iPhone app, both widget
extensions, the Mac host and the `PeeringKit`, `RemoteCore` and `SSHCore` packages. Two other agents
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
| Peering/Localizable.xcstrings | 1615 | 1632 | 1813 | 181 |
| PeeringHost/Localizable.xcstrings | 276 | 286 | 435 | 149 |
| PeeringWidget/Localizable.xcstrings | 46 | 46 | 47 | 1 |
| PeeringHostWidget/Localizable.xcstrings | 13 | 13 | 13 | 0 |
| Peering/AppShortcuts.xcstrings | 9 | 9 | 9 | 0 |
| Peering/InfoPlist.xcstrings | 5 | 5 | 5 | 0 |
| PeeringHost/InfoPlist.xcstrings | 8 | 8 | 8 | 0 |

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
through `HostWireText.localized(_:)` (`apple/Peering/Session/HostWireText*.swift`) at the point of
display: exact sentences by `switch`, sentences with a path, name or number by
`SentenceTemplate` (`PeeringKit`, tested). No protocol change: an unknown sentence, or one from a
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

Wire text that is still not mapped, with the reason:

- `ErrorPayload.message` for any code other than the ones above and the capture-recovery notice
  (owned by another agent), and the relay sentences ("The relay refused the session: ...",
  `RelayProtocolError`, relay `timedOut`), which another agent is working on.
- `CaptureError.errorDescription` ("macOS is not letting this app record the screen...", the stream
  and encoder failures). It feeds the capture-recovery notice, so it stays with that mapping.
- The text of operating system and library errors that is interpolated into a sentence
  (`error.localizedDescription`, NIO, Citadel and the output of `pmset` and `sudo`). It is shown as the
  system wrote it, inside the localized sentence around it.

Texts that reach the phone as operating system notifications cannot be mapped there. They are
written on the Mac, so they follow the Mac's language: terminal pushes, the Live Activity alerts
(`LiveActivityPushBuilder.alertText`, passed as plain strings to the relay), the test push, and now
the agent approval and finish pushes (see below). A phone and Mac set to different languages will see
the Mac's. Fixing that needs a locale or a `loc-key` on the registration or the relay payload, which
is a protocol change, so it is left.

## Second pass: what the first audit left English

Every item the first audit listed under "What remains" is fixed, confirmed, or listed under "Confirmed and left".

### Mac host Activity feed

`HostModel.record(_:level:)` now takes a `LocalizedStringResource`; `record(verbatim:)` is for text
that is already a finished sentence from the system. `HostLogEntry` keeps the resource for the window
and an English copy (`message`, computed with the resource's locale set to `en`). The window resolves
the resource at display time, in the Mac's current language (`HostLogEntry.text`). The unified log,
the diagnostics report and the copied log all use the English copy, so support reads English whatever
the Mac is set to. Nested resources localize with the outer sentence (`"... \(reason)"` where
`reason` is itself a resource), which is how a refused Privacy Mode cover and a failed display add
carry a translated reason.

The feed comes from about 70 call sites. They are keyed in the host catalog: 136 new entries,
including the relay registration lines, the `VideoCoordinator` status lines (the `onStatus` callbacks
now carry a resource), `HostEvent.failed` (a resource, with `failed(verbatim:)` and
`failed(because:)`), the handshake errors of `HostServer.Failure`, `HostSession.SessionError` and
`VirtualDisplay.Failure` (each has `message` for the window and keeps `errorDescription` in English
for the log and for the error frame sent to the peer), and the sleep prevention lines.

Also found and fixed on the way (all English `String` values reaching `Text`): the host status line
("Starting...", "Waiting for a device"), the test push result, the lid-close explanation alert, the
daily wake caption, the "waiting for a password" push fallback, the administrator prompt texts, the
session duration helpers (now `TerminalCommandFinishDetector.spokenDuration`), "Unknown device",
"Measuring...", the lid-close row title in the menu bar, and a pairing sentence whose first branch
fell back to `String` because its sibling branch was `String(localized:)`.

### Agent pushes

`PeeringKit` cannot have strings extracted, so `AgentNotificationText.approval/finished`,
`AgentTurnDigest.detail` and `ClaudeHookBroker` take an `AgentNotificationWords` value
(`AgentNotificationWords.swift`). `.english` is the default and what the tests assert; the host builds
`AgentNotificationWords.localized` (`AgentNotificationWords+Localized.swift`) from the host catalog and
passes it where it composes a push. "N files changed" has plural variations (one and other in en, de,
es, fr, it, pt-BR; one, few, many and other in ru; other in ja, ko, zh-Hans). The duration uses
`spokenDuration`. New tests: `AgentNotificationWordsTests`.

### Agent text shown on the phone

The chat transcript keeps English (`AgentPause.isPaused` reads the pause notice), so the phone maps at
display with `HostWireText.agentLine`: pause and expiry notices, the folder access notes, the adapter
exit and "too long" lines (with the CLI's stderr tail kept after the first line), git outcomes,
`AgentGitRefusal` and `AgentGitLocator.missingMessage`. `HostWireText.localized` now also maps a
sentence followed by a tail. Display sites wrapped: transcript notice and failure rows, the chat
failure line, the Changes message, the commit sheet result and push reason, the Live Activity banner
body. `AgentRecap` (the opening message of a replacement chat) is a prompt for the agent and stays
English.

### SSHCore and RemoteCore sentences

`HostWireText+SSH.swift` maps the file service sentences, the key and port forward errors and the
forwarder statuses by exact text or `SentenceTemplate`; `forwardSummary` replaces `SSHForwardState.summary`
in the forwards sheet. `HostWireText+Handshake.swift` maps the handshake internals (hello, commitment,
reveal, result, certificate, secure random bytes, lost state, protocol mismatch, "Expected X from the
Mac, got Y.", identity). `errorDescription` is untouched, so logs stay English. `pinsUnreadable`,
`handshakeTimedOut`, relay `timedOut` and the capture-recovery notice mapping were left to the other
agent.

### Mosaic placeholder

The five texts drawn into the picture go through `String(localized:)`, so the card follows the Mac's
language.

### Missed by the first audit (the same method, a better detector)

The detector compares each source literal with the catalog and with the strings Xcode extracted for
that line (`.stringsdata`). A literal that is a catalog key but was not extracted is a `String` that
SwiftUI shows verbatim. 34 of them are fixed: Deny and Allow in the approval sheet, the file browser
create and delete titles and its default names, the on-screen key labels (Tab, Copy, Paste, Enter,
Delete, the arrows, Escape, End) and their accessibility labels, the remote status chips (Lock,
Connect, Mosaic, Connected), "Path" and "None" in Settings, the Servers, History and FAQ headers,
"Next" in onboarding, "now" in the notification card example, and the sample prompts in the empty
chat. The terminal card age and the turn summary duration used "4m 12s" style English abbreviations
and now use `spokenDuration`.

### Confirmed and left

- `SessionPiP.lastAttempt` and `lastRefusal`: written and logged, never shown. Left as they are.
- `HostDiagnostics`, `Diagnostics` and the copied activity log: English on purpose, for support.
- The Developer section of Settings is `#if DEBUG` and not in any build a user receives; its footer is
  not in the catalog.
- Virtual display names ("Peering Display 2", "Peering Phone Display") are what macOS and the phone list
  as the display's name and are persisted by the window server, so they stay a stable English name.
- Quotation marks around a command in the terminal-finished sentence are still always curly English
  quotes, and the `Stop ${applicationName}` App Shortcut phrase exists in English only.
- `HostPickerView+HomeCards` matches English wire text on purpose (see the first pass).
- The accessibility label of the recent sessions summary is three joined fragments; each fragment is
  translated with its own punctuation, so it reads correctly, but a single sentence would let a
  language reorder the parts.

## Stale and unreferenced entries (reported, not deleted)

`check-localization.py --stale` lists them.

| Catalog | stale |
| --- | --- |
| Peering/Localizable.xcstrings | 269 |
| PeeringHost/Localizable.xcstrings | 5 |
| Peering/AppShortcuts.xcstrings | 5 |

Do not delete these blindly. Xcode does not extract strings from Swift packages, so every
`String(localized:)` in `PeeringKit` (session notifications such as "Connected to %@", the relay
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

Second pass, in the same order of doubt:

1. **Technical vocabulary kept loose in all nine**: "window server" (Window-Server, servidor de
   ventanas, serveur de fenêtres, window server, ウインドウサーバ, 윈도 서버, servidor de janelas,
   оконный сервер, 窗口服务器), "commitment" and "reveal" of the pairing handshake (Commitment,
   compromiso, engagement, impegno, コミットメント, 커밋먼트, compromisso, обязательство, 承诺值; and
   Offenlegung, revelación, révélation, rivelazione, 公開値, 공개 값, revelação, раскрытие, 披露值), "power
   assertion" (left as `power assertion` in Russian), "listener" (Listener, listener, écoute,
   listener, リスナー, 리스너, listener, прослушивание, 监听器).
2. **Mission Control shortcut names** quoted in the desktop switch warning ("Move left a space" and
   "Move right a space"): written to match macOS in each language from memory, not checked against a
   Mac set to that language. zh-Hans uses 调度中心 for Mission Control; the others keep the English name.
3. **Plural forms** of "N files changed" in Russian (few and many) and the unit nouns in ja and ko.
4. **Push tone**: "Needs your approval.", "%@ asks", "The turn finished." in the Mac's language;
   the same turn vocabulary as the first pass (Durchlauf, turno, tour, ターン, 차례, vez, ход, 轮).
5. **Activity feed lines** are short event notes; the ones with two clauses use a semicolon, which ja,
   ko and zh-Hans render with their own punctuation or a plain stop.
6. **Desktop** as a Mission Control space: Schreibtisch, Escritorio, Bureau, Scrivania, デスクトップ,
   데스크탑, Mesa, рабочий стол, 桌面. pt-BR "Mesa" follows the existing Finder-folder term and may read
   oddly next to a number.

Strings worth a native read because the meaning is easy to flip:

- "The Mac has no saved credential for this remote, and git cannot ask for one from here."
- "Sleep was still disabled by Peering from a previous run; this Mac sleeps on a closed lid again."
- "Battery is down to %lld%%, so this Mac sleeps normally again. Kept awake with the lid shut it would have
  run the battery flat rather than sleeping through the last of it."
- "This Mac was already set to stay up with the lid closed, and not by Peering; it is being left as it
  was found."

- "Something at this address is not the Mac you paired with (%@)..." and "This iPhone has no
  pairing on file for that Mac (%@)..." (the security explanation on an identity change).
- "That is too much of this Mac to delete."
- "That transfer was sent in pieces this Mac cannot accept."
- "... finished after %@." (the word order around the duration in ja, ko, ru and zh-Hans).
- The three `created folder`, `created file` and `renamed A to B` log notes (lowercase fragments).
