package pl.dmq.peering.feature.files

/** A run of inline text with one style. */
data class MarkdownSpan(val text: String, val style: Style) {
    enum class Style { PLAIN, BOLD, ITALIC, CODE }
}

/** Inline marks: `code`, **bold** and *italic*. An unclosed mark stays as typed. */
object MarkdownSpans {
    fun parse(text: String): List<MarkdownSpan> {
        val spans = mutableListOf<MarkdownSpan>()
        val plain = StringBuilder()
        var index = 0

        fun flushPlain() {
            if (plain.isNotEmpty()) spans += MarkdownSpan(plain.toString(), MarkdownSpan.Style.PLAIN)
            plain.clear()
        }

        while (index < text.length) {
            val (mark, style) = markAt(text, index) ?: (null to null)
            val close = if (mark == null) -1 else text.indexOf(mark, index + mark.length)
            if (mark == null || style == null || close <= index + mark.length) {
                plain.append(text[index])
                index++
                continue
            }
            flushPlain()
            spans += MarkdownSpan(text.substring(index + mark.length, close), style)
            index = close + mark.length
        }
        flushPlain()
        return spans
    }

    private fun markAt(text: String, index: Int): Pair<String, MarkdownSpan.Style>? = when {
        text.startsWith("**", index) -> "**" to MarkdownSpan.Style.BOLD
        text.startsWith("`", index) -> "`" to MarkdownSpan.Style.CODE
        text.startsWith("*", index) -> "*" to MarkdownSpan.Style.ITALIC
        else -> null
    }
}
