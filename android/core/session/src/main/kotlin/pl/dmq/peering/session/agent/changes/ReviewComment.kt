package pl.dmq.peering.session.agent.changes

/** One remark on a file, or on a line of its diff. [line] is absent for a remark on the whole file. */
data class ReviewComment(
    val id: Long,
    val path: String,
    val text: String,
    val line: Int? = null,
    val onRemovedLine: Boolean = false,
    val quote: String? = null,
)

/** The wording that is not the comments themselves, in the language of the screen it is sent from. */
data class ReviewPromptWords(
    val intro: String,
    val removedLine: String,
    val moreLeftOut: (count: Int) -> String,
)

/** Collected comments written as one prompt. */
object ReviewPrompt {
    /** The computer refuses a prompt over 64 KiB, so a long review stops short and says how many it left out. */
    const val MAXIMUM_BYTES = 60 * 1024
    private const val HEADROOM = 200
    private const val QUOTE_LIMIT = 160

    fun text(comments: List<ReviewComment>, words: ReviewPromptWords, limit: Int = MAXIMUM_BYTES): String {
        val text = StringBuilder(words.intro)
        var size = words.intro.toByteArray().size
        var left = 0
        for (comment in comments) {
            val entry = "\n\n" + format(comment, words)
            val entrySize = entry.toByteArray().size
            if (left > 0 || size + entrySize > limit - HEADROOM) {
                left++
                continue
            }
            text.append(entry)
            size += entrySize
        }
        if (left > 0) text.append("\n\n").append(words.moreLeftOut(left))
        return text.toString()
    }

    fun location(comment: ReviewComment, words: ReviewPromptWords): String {
        val line = comment.line ?: return comment.path
        val place = "${comment.path}:$line"
        return if (comment.onRemovedLine) place + " " + words.removedLine else place
    }

    private fun format(comment: ReviewComment, words: ReviewPromptWords): String {
        val lines = mutableListOf(location(comment, words))
        comment.quote?.trim()?.takeIf { it.isNotEmpty() }?.let { lines += "> " + it.take(QUOTE_LIMIT) }
        lines += comment.text.trim()
        return lines.joinToString("\n")
    }
}
