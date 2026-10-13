# Android Agents: gaps against the iPhone app

Swift reference: `apple/Peering/Agent/*`, `apple/RemoteCore/.../AgentWire.swift`, `apple/PeeringKit/.../AgentChatEnding.swift`.
Status is as of the start of this pass. "Closed" rows name the commit area that closed them.

| Capability (iPhone) | Android before | Status |
| --- | --- | --- |
| Agent list from `agentChatAgents`, gated by `supportsAgentChat` | Done (AgentCatalog, hub presenter) | Done |
| Host without `agentChatAgents` offers Claude Code and Codex (the iPhone default) | Offered nothing, so the hub read as unsupported | Closed |
| `supportsAgentList` filters offered agents to the installed ones (terminal `agents` request) | Absent; every declared agent is offered | Open (terminal code is owned elsewhere) |
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
| Changes review: changed files with diffs, line and file comments sent back as one prompt, commit and push (`changes`, `commit`, `push`) | Wire only | Closed (filters, the All files tree and the agent-edit overlay are not built) |
| Web preview: address field, servers found on the usual ports, pages fetched through the connection | Absent | Closed (no hello flag exists for it, so it is offered with agent chats; requests that send a body are not carried because Android's WebView does not hand them over) |
| Rename a chat (this phone only, as on the iPhone) | Absent | Closed |
| Attach files and photos to a prompt (sent into the chat's folder, then `@path`) | Absent | Closed |
| Saved prompts beside the suggestions in an empty chat | Absent | Closed |
| To review inbox, Lock Screen approvals, slash and mention hints | Absent | Open |
| Continue in a new chat from an expired conversation (`AgentRecap`) | Absent | Open |

Windows hosts declare a subset of these flags; every request above is sent only when its flag is set.
