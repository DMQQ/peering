package pl.dmq.peering.session.agent.changes

import pl.dmq.peering.wire.AgentChangeKind
import pl.dmq.peering.wire.AgentChangedFile

/** A one-line commit message worked out from which files changed and how, with nothing guessed about why. */
object CommitDraft {
    fun message(files: List<AgentChangedFile>): String {
        val names = displayNames(files)
        val segments = listOf(
            "Add" to files.filter { it.kind == AgentChangeKind.ADDED || it.kind == AgentChangeKind.UNTRACKED },
            "Update" to files.filter { it.kind == AgentChangeKind.MODIFIED },
            "Remove" to files.filter { it.kind == AgentChangeKind.DELETED },
        ).filter { it.second.isNotEmpty() }
        val clauses = segments.mapIndexed { index, (verb, group) ->
            val word = if (index == 0) verb else verb.lowercase()
            word + " " + objectOf(group.map { names.getValue(it.path) })
        }
        return join(clauses)
    }

    /** The file's name, or its path where two chosen files share a name. */
    private fun displayNames(files: List<AgentChangedFile>): Map<String, String> {
        val last = { path: String -> path.substringAfterLast('/') }
        val counts = files.groupingBy { last(it.path) }.eachCount()
        return files.associate { it.path to if ((counts[last(it.path)] ?: 0) > 1) it.path else last(it.path) }
    }

    private fun objectOf(names: List<String>): String = when (names.size) {
        1 -> names[0]
        2 -> "${names[0]} and ${names[1]}"
        3 -> "${names[0]}, ${names[1]} and ${names[2]}"
        else -> "${names.size} files"
    }

    private fun join(clauses: List<String>): String =
        if (clauses.size < 2) clauses.firstOrNull().orEmpty() else clauses.dropLast(1).joinToString(", ") + " and " + clauses.last()
}
