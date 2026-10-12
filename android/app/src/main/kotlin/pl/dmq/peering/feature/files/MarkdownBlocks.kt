package pl.dmq.peering.feature.files

/** A block of a markdown file as the preview draws it. Text still holds inline marks; see [MarkdownSpans]. */
sealed interface MarkdownBlock {
    data class Heading(val level: Int, val text: String) : MarkdownBlock

    data class Paragraph(val text: String) : MarkdownBlock

    data class Bullet(val text: String, val depth: Int) : MarkdownBlock

    data class Numbered(val number: Int, val text: String, val depth: Int) : MarkdownBlock

    data class Quote(val text: String) : MarkdownBlock

    data class Code(val text: String) : MarkdownBlock

    data object Rule : MarkdownBlock
}

/** The common subset of markdown: headings, lists, quotes, fenced code, rules and paragraphs. */
object MarkdownBlocks {
    private val heading = Regex("^(#{1,6})\\s+(.*?)\\s*#*\\s*$")
    private val bullet = Regex("^(\\s*)[-*+]\\s+(.*)$")
    private val numbered = Regex("^(\\s*)(\\d{1,9})[.)]\\s+(.*)$")
    private val rule = Regex("^\\s*([-*_])(\\s*\\1){2,}\\s*$")

    fun parse(text: String): List<MarkdownBlock> {
        val blocks = mutableListOf<MarkdownBlock>()
        val paragraph = mutableListOf<String>()
        val quote = mutableListOf<String>()
        var fence: MutableList<String>? = null

        fun flush() {
            if (paragraph.isNotEmpty()) blocks += MarkdownBlock.Paragraph(paragraph.joinToString(" "))
            if (quote.isNotEmpty()) blocks += MarkdownBlock.Quote(quote.joinToString(" "))
            paragraph.clear()
            quote.clear()
        }

        for (line in text.lines()) {
            val open = fence
            if (line.trimStart().startsWith("```")) {
                if (open == null) {
                    flush()
                    fence = mutableListOf()
                } else {
                    blocks += MarkdownBlock.Code(open.joinToString("\n"))
                    fence = null
                }
                continue
            }
            if (open != null) {
                open += line
                continue
            }
            val kind = blockOf(line)
            when {
                line.isBlank() -> flush()
                kind != null -> {
                    flush()
                    blocks += kind
                }
                line.trimStart().startsWith(">") -> {
                    if (paragraph.isNotEmpty()) flush()
                    quote += line.trimStart().removePrefix(">").trim()
                }
                else -> {
                    if (quote.isNotEmpty()) flush()
                    paragraph += line.trim()
                }
            }
        }
        fence?.let { blocks += MarkdownBlock.Code(it.joinToString("\n")) }
        flush()
        return blocks
    }

    private fun blockOf(line: String): MarkdownBlock? {
        heading.matchEntire(line)?.let { return MarkdownBlock.Heading(it.groupValues[1].length, it.groupValues[2]) }
        if (rule.matches(line)) return MarkdownBlock.Rule
        bullet.matchEntire(line)?.let { return MarkdownBlock.Bullet(it.groupValues[2], depthOf(it.groupValues[1])) }
        numbered.matchEntire(line)?.let {
            return MarkdownBlock.Numbered(it.groupValues[2].toInt(), it.groupValues[3], depthOf(it.groupValues[1]))
        }
        return null
    }

    private fun depthOf(indent: String): Int = indent.length / 2
}
