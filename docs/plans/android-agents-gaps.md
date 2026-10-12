# Android Agents: gaps against the iPhone app

Swift reference: `apple/MacCast/Agent/*`, `apple/RemoteCore/.../AgentWire.swift`, `apple/MacCastKit/.../AgentChatEnding.swift`.
Status is as of the start of this pass. "Closed" rows name the commit area that closed them.

| Capability (iPhone) | Android before | Status |
| --- | --- | --- |
| Agent list from `agentChatAgents`, gated by `supportsAgentChat` | Done (AgentCatalog, hub presenter) | Done |
| `supportsAgentList` gate for the chat list request | List was gated on chat only | Closed |
| Chat cards with state, pending approvals, activity age | Done | Done |
| Start a chat: agent, then folder via host browse, recents | Done | Done |
| Model picker (`supportsAgentModelPicker`) | Done | Done |
| Permission modes (`supportsAgentPermissionModes`) | Done | Done |
| Usage: context bar, usage and limits sheet (`supportsAgentUsage`) | Events applied, nothing shown | Closed |
| Streaming transcript: markdown, code blocks, tool cards, plan, sub-agents, turn summary | Done | Done |
| Approvals in the transcript: allow, deny, options, questions | Done | Done |
| Composer: send, queue, stop, attachments | Done | Done |
| Pause (`supportsAgentPause`): "Stop and move to history", paused chats leave Chats for History | Wire request only, no state, no UI | Closed |
| End action chosen by the same rule as the iPhone (`AgentEndAction`: pause a quiet chat with a conversation, close otherwise) | Always close | Closed |
| Session import (`supportsAgentSessionImport`): list Claude conversations started on the computer and continue one | `Resumable` kept raw, never decoded | Closed |
| Chat screen top bar with 48 dp back and an options menu (usage, stop and move to history, close) | Text link back, no menu | Closed |
| Empty states with the mascot (no chats, empty chat, nothing to import) | Plain text | Closed |
| Changes review, commit and push (`changes`, `commit`, `push`) | Wire only | Open |
| Web preview, rename, To review inbox, Lock Screen approvals, slash and mention hints, prompt templates | Absent | Open |
| Continue in a new chat from an expired conversation (`AgentRecap`) | Absent | Open |

Windows hosts declare a subset of these flags; every request above is sent only when its flag is set.
