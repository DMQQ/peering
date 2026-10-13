package pl.dmq.peering.session.agent

import pl.dmq.peering.wire.RemoteDirectoryEntry

/** The `@path` being typed at the end of a message: the folder it points into and the start of the name inside it. */
class MentionQuery private constructor(
    /** What follows the `@`, as typed. */
    val typed: String,
    /** The part up to and including the last slash, relative to the project (or absolute). */
    val folderPart: String,
    val namePart: String,
) {
    /** The folder to list, on the computer. */
    fun folder(project: String): String {
        val base = if (folderPart.startsWith("/")) folderPart else project.trimEnd('/') + "/" + folderPart
        val segments = ArrayList<String>()
        for (segment in base.split('/')) {
            when (segment) {
                "", "." -> Unit
                ".." -> if (segments.isNotEmpty()) segments.removeAt(segments.lastIndex)
                else -> segments += segment
            }
        }
        return "/" + segments.joinToString("/")
    }

    /** What the folder holds that fits what has been typed: names starting with it first, then folders, then the rest. */
    fun matches(entries: List<RemoteDirectoryEntry>?): List<RemoteDirectoryEntry> {
        entries ?: return emptyList()
        val showsHidden = namePart.startsWith(".")
        val lowered = namePart.lowercase()
        return entries
            .filter { showsHidden || !it.name.startsWith(".") }
            .filter { namePart.isEmpty() || it.name.contains(namePart, ignoreCase = true) }
            .sortedWith(
                compareByDescending<RemoteDirectoryEntry> { it.name.lowercase().startsWith(lowered) }
                    .thenByDescending { it.isDirectory }
                    .thenBy(String.CASE_INSENSITIVE_ORDER) { it.name },
            )
    }

    /** [draft] with the mention being typed completed to [path]: a folder keeps the mention open one level deeper, a file ends it. */
    fun replacing(draft: String, path: String, isFolder: Boolean): String {
        val start = mentionStart(draft) ?: return draft
        return draft.substring(0, start) + "@" + path.replace(" ", "\\ ") + if (isFolder) "/" else " "
    }

    companion object {
        /** The last word of the draft, when it starts with `@`. The caret is the end of the text, where a mention is nearly always being typed. */
        fun of(draft: String): MentionQuery? {
            val start = mentionStart(draft) ?: return null
            val typed = draft.substring(start + 1)
            val slash = typed.lastIndexOf('/')
            return if (slash >= 0) MentionQuery(typed, typed.substring(0, slash + 1), typed.substring(slash + 1))
            else MentionQuery(typed, "", typed)
        }

        private fun mentionStart(draft: String): Int? {
            val at = draft.lastIndexOf('@')
            if (at < 0) return null
            if (draft.substring(at + 1).any { it.isWhitespace() }) return null
            if (at > 0 && !draft[at - 1].isWhitespace()) return null
            return at
        }
    }
}
