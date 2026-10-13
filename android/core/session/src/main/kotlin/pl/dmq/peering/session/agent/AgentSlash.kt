package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.RemoteDirectoryEntry

/** One thing that can be typed after a slash. */
data class SlashSuggestion(val name: String, val detail: SlashDetail, val kind: SlashKind)

/** Ordered as the list sorts them: the app's own first. */
enum class SlashKind {
    /** Handled by this app, never sent: it opens one of its own screens. */
    APP,

    /** Typed to the CLI, which runs it even without a terminal. */
    BUILTIN,
    COMMAND,
    SKILL,
}

/** What the hint says under the name. The wording belongs to the screen, which owns the translations. */
enum class SlashDetail { USAGE, MODEL, RENAME, COMPACT, CLEAR, THIS_PROJECT, YOURS }

/**
 * What can be typed after a `/` at the start of a message. The CLI runs a command or a skill from its text alone, so the
 * hints are names read off the computer's own folders, plus the few built-ins that work without a terminal and the ones
 * this app answers itself.
 */
object AgentSlash {
    private const val CLAUDE = "claude"

    /** What follows the slash, while the draft is still one word; null when the draft is anything else. */
    fun query(draft: String): String? = if (draft.startsWith("/") && draft.none { it.isWhitespace() }) draft.drop(1) else null

    /** The user's home, read off the project's own path: the phone is not told it. */
    fun home(project: String): String? {
        val parts = project.split('/').filter { it.isNotEmpty() }
        return if (parts.size >= 2 && parts[0] == "Users") "/Users/${parts[1]}" else null
    }

    /** The folders a Claude Code command or skill can live in, the project's first because it wins. */
    fun folders(project: String, agentId: String): List<String> {
        if (agentId != CLAUDE) return emptyList()
        val base = project.trimEnd('/')
        val home = home(project)
        return listOf("$base/.claude/commands", "$base/.claude/skills") +
            if (home != null) listOf("$home/.claude/commands", "$home/.claude/skills") else emptyList()
    }

    fun suggestions(
        typed: String,
        agentId: String,
        project: String,
        offersUsage: Boolean,
        offersModel: Boolean,
        listing: (String) -> List<RemoteDirectoryEntry>?,
    ): List<SlashSuggestion> {
        val found = buildList {
            if (offersUsage) add(SlashSuggestion("usage", SlashDetail.USAGE, SlashKind.APP))
            if (offersModel) add(SlashSuggestion("model", SlashDetail.MODEL, SlashKind.APP))
            add(SlashSuggestion("rename", SlashDetail.RENAME, SlashKind.APP))
            if (agentId == CLAUDE) {
                add(SlashSuggestion("compact", SlashDetail.COMPACT, SlashKind.BUILTIN))
                add(SlashSuggestion("clear", SlashDetail.CLEAR, SlashKind.BUILTIN))
            }
            for (folder in folders(project, agentId)) {
                val entries = listing(folder) ?: continue
                val isSkill = folder.endsWith("/skills")
                val scope = if (folder.startsWith(project)) SlashDetail.THIS_PROJECT else SlashDetail.YOURS
                for (entry in entries.filterNot { it.name.startsWith(".") }) {
                    if (isSkill && entry.isDirectory) {
                        add(SlashSuggestion(entry.name, scope, SlashKind.SKILL))
                    } else if (!isSkill && !entry.isDirectory && entry.name.endsWith(".md")) {
                        add(SlashSuggestion(entry.name.dropLast(3), scope, SlashKind.COMMAND))
                    }
                }
            }
        }
        val lowered = typed.lowercase()
        return found
            .distinctBy { it.name }
            .filter { typed.isEmpty() || it.name.contains(typed, ignoreCase = true) }
            .sortedWith(
                compareByDescending<SlashSuggestion> { it.name.lowercase().startsWith(lowered) }
                    .thenBy { it.kind.ordinal }
                    .thenBy(String.CASE_INSENSITIVE_ORDER) { it.name },
            )
    }
}
