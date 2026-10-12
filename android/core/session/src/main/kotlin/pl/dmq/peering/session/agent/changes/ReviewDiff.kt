package pl.dmq.peering.session.agent.changes

enum class DiffLineKind { HUNK, ADDED, REMOVED, CONTEXT }

/** [oldNumber] and [newNumber] are the line's place before and after the change; a hunk header has neither. */
data class DiffLine(
    val id: Int,
    val kind: DiffLineKind,
    val oldNumber: Int?,
    val newNumber: Int?,
    val text: String,
) {
    val isCommentable: Boolean get() = kind != DiffLineKind.HUNK

    /** What a comment on this line points at: the new file's line, or the old one's for a removed line. */
    val commentNumber: Int? get() = if (kind == DiffLineKind.REMOVED) oldNumber else newNumber
}

/** A unified diff split into numbered lines, so a comment can name `file:line`. Everything before the first `@@` is dropped. */
object ReviewDiff {
    fun lines(diff: String): List<DiffLine> {
        val result = mutableListOf<DiffLine>()
        var old = 0
        var new = 0
        var inHunk = false
        for (text in diff.split('\n')) {
            if (text.startsWith("@@")) {
                val (oldStart, newStart) = starts(text)
                old = oldStart
                new = newStart
                inHunk = true
                result += DiffLine(result.size, DiffLineKind.HUNK, null, null, text)
            } else if (inHunk) {
                when {
                    text.startsWith("+") -> {
                        result += DiffLine(result.size, DiffLineKind.ADDED, null, new, text.drop(1))
                        new++
                    }
                    text.startsWith("-") -> {
                        result += DiffLine(result.size, DiffLineKind.REMOVED, old, null, text.drop(1))
                        old++
                    }
                    text.startsWith("\\") -> Unit
                    else -> {
                        result += DiffLine(result.size, DiffLineKind.CONTEXT, old, new, text.drop(1))
                        old++
                        new++
                    }
                }
            }
        }
        return result
    }

    /** `@@ -12,5 +14,7 @@ context` gives 12 and 14; a header that does not parse starts both at 1. */
    private fun starts(header: String): Pair<Int, Int> {
        val numbers = header.split(' ').drop(1).take(2).map { it.drop(1).substringBefore(',').toIntOrNull() }
        val old = numbers.getOrNull(0)
        val new = numbers.getOrNull(1)
        return if (old != null && new != null) old to new else 1 to 1
    }
}
