package pl.dmq.peering.feature.terminal

/** A command line agent a shell can start. [command] is what the computer reports as installed and what is typed. */
data class TerminalAgent(val id: String, val name: String, val command: String) {
    companion object {
        val all: List<TerminalAgent> = listOf(
            TerminalAgent("claude", "Claude Code", "claude"),
            TerminalAgent("codex", "Codex", "codex"),
            TerminalAgent("opencode", "OpenCode", "opencode"),
            TerminalAgent("hermes", "Hermes", "hermes"),
            TerminalAgent("gemini", "Gemini CLI", "gemini"),
            TerminalAgent("aider", "Aider", "aider"),
        )

        fun byId(id: String): TerminalAgent? = all.firstOrNull { it.id == id }
    }
}
