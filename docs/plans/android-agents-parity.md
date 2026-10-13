# Android Agents parity checklist

Source: `apple/Peering/Terminal/TerminalHubScreen*.swift` (the Agents tab of the hub), `Connection/SessionCards.swift`, `Agent/Hub`, `Agent/Chat`, `Agent/Composer`, `Agent/Transcript`, `Agent/Approval`.

Page column: 16 pt side inset, 20 pt between sections, 28 pt at the bottom, 70 pt of room under the list for the dock.

## 1. Agents hub (the Agents tab)

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Hub tab switcher (Agents, Terminals, Files) | Not built here: the Terminals and Files hubs belong to other screens. The page is the Agents tab on its own. |
| 2 | Page heading: serif 34 "Agents", subheadline detail ("N open on your computer" or "Chat with a coding agent on your computer") | `HubHeading` |
| 3 | Help button after the guide was read, bringing it back | `HubHeading` question mark, `HubGuideCard` state in `HubScreen` |
| 4 | Guide card "How agents work": title serif 22, rows (tile, title, detail), "Got it" ink capsule | `HubGuideCard`, three rows: the "To review" row is left out because Android has no review inbox |
| 5 | To review card | Not built: Android has no review inbox. |
| 6 | Chats section: label with chat glyph, then session cards 10 apart | `ChatsSection` with `SectionLabel` |
| 6a | Session card: 42 tile with agent glyph, title 15.5 semibold, state pill (outlined, tinted), folder glyph, folder name in monospace, agent name unless the title has it, optional last reply preview in a tinted box | `SessionCardRow` |
| 6b | Tap opens the chat | `SessionCardRow` click, `presenter.openSession` |
| 6c | Long press menu: New chat here, Rename, Stop and move to history, Close | `SessionCardMenu` on long press: New chat here, Rename (a name on this phone only), Stop and move to history, Close. |
| 6d | Close confirmation alert | `PeeringAlert` "End chat" before `closeSession` |
| 7 | Active on your computer: label with laptop glyph, history card of resumable conversations in use elsewhere | `HistoryCard` entries, tapping asks the "may be open on your computer" confirmation |
| 8 | Notice: no supported agents found | `AgentsNotice` with tile and caption |
| 9 | Empty state: "No chats yet" and the sentence under the animated sample | `AgentEmptyState` (mascot in place of the typing animation) |
| 10 | History: label with clock glyph, grouped card (Today, Yesterday, date), 32 tile, title, detail, time and a restart glyph per row | `HistorySection` over paused chats and resumable conversations |
| 10a | "Clear" beside the History label | Not built: it clears the iPhone's own terminal launch log, which Android does not keep. |
| 10b | Footnote when the computer has no conversations | Not built: the port cannot tell "not listed yet" from "none found". |
| 11 | Dock: floating bar over the page, ink capsule with the agent glyph in a white circle and "Chat with Claude Code"; "Choose an agent" when none is selected | `HubDock` |
| 11a | Hold the dock button to change agent | `combinedClickable` long press opens the picker |
| 11b | CLI button beside the dock capsule | Not built: it runs the agent in a terminal, which is the Terminals hub's job. |
| 12 | Agent picker: dim scrim, a column of agent cards (50 tile, serif 19 name, status line, check circle) rising out of the bar | `AgentPicker` scrim and `AgentHubCard` column |
| 12a | Agent card status line: "N waiting on you", "N working", "N open" and last used, or "Last used ..." / "Never used" | `AgentHubCard` and `AgentUsage` |

## 2. Folder picker (pushed page after Chat with)

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Navigation title: folder name, back arrow, ancestors menu | `FolderPage` top bar with back and the folder name; the ancestors menu is not built |
| 2 | Waiting note with computer glyph | `FolderPage` list head |
| 3 | Failure line in danger | `FolderPage` list head |
| 4 | Recent folders (home only, three): label, rows with clock tile, path, "Work here again", turn arrow | `RecentFolders` |
| 5 | Up row: arrow tile, "..", "Up one level" (not at home) | `FolderUpRow` |
| 6 | Empty text "This folder has no folders inside it." or no match | `FolderPage` |
| 7 | Folder rows: folder tile, name, "Folder", chevron, hairline between | `FolderRow` |
| 8 | Path line in monospace, then "The agent can read and change files in the folder you choose." | `FolderPage` footer |
| 9 | Bottom bar: search field "Search in <folder>", hidden-folders toggle, "Use" ink capsule | `FolderBar` |

## 3. Chat screen

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Top bar: back, centred agent name 15 semibold over the directory in monospace 11 | `ChatTopBar` |
| 2 | More menu: Usage and limits, Changes, Web preview, Rename, Stop and move to history, divider, Close chat | `ChatMenu`: Usage and limits, Changes, Web preview (where the computer supports it), Rename, Stop and move to history, divider, Close chat. |
| 3 | Close confirmation | `PeeringAlert` |
| 4 | Tab strip over the chat when several chats are open | Not built: the hub is the switcher on Android. |
| 5 | Loading state: spinner and "Loading the conversation" | `HistoryLoading` |
| 6 | Empty chat: agent tile, serif 30 "What are we working on?", guide card "Before you start", three suggestion rows (34 tile, title, detail, up-left arrow), saved prompts | `EmptyChat`; the guide keeps only its permissions row (slash and Changes do not exist here); saved prompts under the suggestions, kept on this phone |
| 6a | Ended chat copy | `EmptyChat` ended branch |
| 7 | Transcript column: 14 side, 10 between rows | `TranscriptList` |
| 7a | User message: right aligned bubble, tinted, with copy and "Ask again" menu | `UserBubble`, long press menu |
| 7b | Assistant reply: markdown, copy on long press | `MarkdownText`, long press copy |
| 7c | Tool card: 28 tile (hand, nosign, cross, check, ellipsis), title, monospace detail 2 lines, status (spinner, Review pill, Denied, Failed, check), tap expands diff and output | `ToolCallCard` |
| 7d | Awaiting approval card shows a "Review" pill that opens the approval sheet | `ToolCallCard` and `ApprovalSheet` |
| 7e | Notice (info glyph, footnote) and failure (warning glyph, danger) lines | `NoticeLine`, `FailureLine` |
| 7f | Turn summary pill: Stopped or Failed, cost, tokens in and out, duration, monospace caption | `TurnSummaryPill` |
| 7g | Queued message: dashed outline, clock pill "Queued, starts when this turn ends", remove on long press | `QueuedPromptRow` (remove is not offered: the port has no unqueue) |
| 7h | Thinking row while working | `ThinkingRow` |
| 7i | "The start of this conversation is no longer on the computer." | `TranscriptList` |
| 7j | Sub-agent strip above the composer | Not built: sub-agent transcripts are one summary row on Android. |
| 8 | Follow-up chips after a turn that changed files | Not built: Changes is in the chat menu. |
| 9 | Option chips row: model chip (cpu glyph), permission chip, spacer, context bar with "70k / 1M" and "5h 40%" | `OptionsBar`, `ModelChip`, `PermissionChip`, `ContextBar` |
| 9a | Model menu: Default, suggestions with check, Custom | `ModelMenu` with Default and the host choices |
| 9b | Permission menu: title, detail and glyph per mode | `PermissionMenu` |
| 10 | Composer: capsule with plus (attach), multi line field "Message" or "Queue a message...", round send, Stop or Queue states | `Composer`; the plus button offers Photo library and Files, uploads through the file browser into the chat's folder, and the tray shows each file |
| 11 | Expired chat: "Continue in a new chat" ink capsule | Not built: no expiry signal on Android |

## 4. Approval sheet

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Header: 30 tile (hand or question), title, subtitle ("Wants to run on your computer", "Asks a question", "Question 1 of 2") | `ApprovalSheet` header |
| 2 | Command or question in a monospace box | `ApprovalSheet` |
| 3 | The agent's reason under it, caption | `ApprovalSheet` |
| 4 | Deny (outlined) and Allow (ink) side by side | `ApprovalSheet` |
| 5 | Question options: outlined rows with label, detail, check or chevron; Back | `ApprovalSheet` options |
| 6 | Presented on its own when the agent asks | `ChatScreen` opens it for the first pending approval; the tool card's Review reopens it |

## 5. Usage sheet

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Title is the agent name, Done button | `UsageSheet` title, system sheet dismiss |
| 2 | Context: percent 28 semibold, "N of M tokens", capsule meter | `UsageSheet` |
| 3 | This chat: Input, Output, Read from cache, Cost | `UsageSheet` |
| 4 | Limit left: label, "N% left", meter, "Renews ..." | `UsageSheet` |
| 5 | Other agents | Not built: Android keeps one open chat per screen |
