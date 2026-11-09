package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.ServerHello

/** The agents the host chats with. A host that does not list them chats with Claude Code and Codex only. */
fun declaredAgents(hello: ServerHello): List<String> = hello.agentChatAgents ?: listOf("claude", "codex")
