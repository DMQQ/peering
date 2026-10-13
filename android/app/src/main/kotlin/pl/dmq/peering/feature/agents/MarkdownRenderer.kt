package pl.dmq.peering.feature.agents

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration

/**
 * Turns an agent's markdown into styled text: paragraphs, headings, bullet and numbered lists, fenced code, bold,
 * italic, inline code and links. Anything else stays as typed, and only http and https links become tappable.
 */
object MarkdownRenderer {
    private val bulletLine = Regex("""^\s*[-*+]\s+(.*)$""")
    private val numberedLine = Regex("""^\s*(\d+)[.)]\s+(.*)$""")
    private val headingLine = Regex("""^#{1,6}\s+(.*)$""")

    fun render(source: String): AnnotatedString = buildAnnotatedString {
        val blocks = parseBlocks(source)
        blocks.forEachIndexed { index, block ->
            if (index > 0) append(separator(blocks[index - 1], block))
            appendBlock(block)
        }
    }

    private sealed interface Block {
        data class Paragraph(val text: String) : Block

        data class Heading(val text: String) : Block

        data class Item(val marker: String, val text: String) : Block

        data class Code(val text: String) : Block
    }

    private fun separator(previous: Block, next: Block): String =
        if (previous is Block.Item && next is Block.Item) "\n" else "\n\n"

    private fun parseBlocks(source: String): List<Block> {
        val reader = BlockReader()
        for (line in source.lines()) reader.accept(line)
        return reader.finish()
    }

    private class BlockReader {
        private val blocks = mutableListOf<Block>()
        private val paragraph = mutableListOf<String>()
        private val code = mutableListOf<String>()
        private var inCode = false

        fun accept(line: String) {
            when {
                line.trimStart().startsWith("```") -> toggleFence()
                inCode -> code += line
                else -> acceptText(line)
            }
        }

        fun finish(): List<Block> {
            if (inCode && code.isNotEmpty()) blocks += Block.Code(code.joinToString("\n"))
            flushParagraph()
            return blocks
        }

        private fun toggleFence() {
            if (inCode) {
                blocks += Block.Code(code.joinToString("\n"))
                code.clear()
            } else {
                flushParagraph()
            }
            inCode = !inCode
        }

        private fun acceptText(line: String) {
            val bullet = bulletLine.matchEntire(line)
            val numbered = numberedLine.matchEntire(line)
            val heading = headingLine.matchEntire(line)
            when {
                line.isBlank() -> flushParagraph()
                bullet != null -> addBlock(Block.Item("•", bullet.groupValues[1]))
                numbered != null -> addBlock(Block.Item("${numbered.groupValues[1]}.", numbered.groupValues[2]))
                heading != null -> addBlock(Block.Heading(heading.groupValues[1]))
                else -> paragraph += line
            }
        }

        private fun addBlock(block: Block) {
            flushParagraph()
            blocks += block
        }

        private fun flushParagraph() {
            if (paragraph.isEmpty()) return
            blocks += Block.Paragraph(paragraph.joinToString("\n"))
            paragraph.clear()
        }
    }

    private fun AnnotatedString.Builder.appendBlock(block: Block) {
        when (block) {
            is Block.Paragraph -> appendInline(block.text)
            is Block.Heading -> {
                pushStyle(SpanStyle(fontWeight = FontWeight.Bold))
                appendInline(block.text)
                pop()
            }
            is Block.Item -> {
                append(block.marker)
                append(" ")
                appendInline(block.text)
            }
            is Block.Code -> {
                pushStyle(SpanStyle(fontFamily = FontFamily.Monospace))
                append(block.text)
                pop()
            }
        }
    }

    private fun AnnotatedString.Builder.appendInline(text: String) {
        var index = 0
        while (index < text.length) {
            index = appendSpanAt(text, index)
        }
    }

    /** Appends whatever starts at [index] and returns the index after it. Unmatched markers are kept as typed. */
    private fun AnnotatedString.Builder.appendSpanAt(text: String, index: Int): Int {
        val consumed = when {
            text[index] == '`' -> appendCode(text, index)
            text.startsWith("**", index) || text.startsWith("__", index) -> appendDelimited(text, index, 2, bold = true)
            text[index] == '*' || (text[index] == '_' && !isWordChar(text, index - 1)) ->
                appendDelimited(text, index, 1, bold = false)
            text[index] == '[' -> appendLink(text, index)
            else -> null
        }
        if (consumed != null) return consumed
        append(text[index])
        return index + 1
    }

    private fun AnnotatedString.Builder.appendCode(text: String, index: Int): Int? {
        val end = text.indexOf('`', index + 1)
        if (end <= index + 1) return null
        pushStyle(SpanStyle(fontFamily = FontFamily.Monospace))
        append(text.substring(index + 1, end))
        pop()
        return end + 1
    }

    private fun AnnotatedString.Builder.appendDelimited(text: String, index: Int, width: Int, bold: Boolean): Int? {
        val marker = text.substring(index, index + width)
        val contentStart = index + width
        val end = text.indexOf(marker, contentStart)
        if (end <= contentStart || text[contentStart].isWhitespace()) return null
        if (!bold && marker == "_" && isWordChar(text, end + width)) return null
        val style = if (bold) SpanStyle(fontWeight = FontWeight.Bold) else SpanStyle(fontStyle = FontStyle.Italic)
        pushStyle(style)
        appendInline(text.substring(contentStart, end))
        pop()
        return end + width
    }

    private fun AnnotatedString.Builder.appendLink(text: String, index: Int): Int? {
        val labelEnd = text.indexOf(']', index + 1)
        if (labelEnd <= index + 1 || !text.startsWith("(", labelEnd + 1)) return null
        val urlEnd = text.indexOf(')', labelEnd + 2)
        if (urlEnd < 0) return null
        val url = text.substring(labelEnd + 2, urlEnd)
        if (!(url.startsWith("https://") || url.startsWith("http://")) || url.any { it.isWhitespace() }) return null
        val link = LinkAnnotation.Url(url, TextLinkStyles(SpanStyle(textDecoration = TextDecoration.Underline)))
        pushLink(link)
        append(text.substring(index + 1, labelEnd))
        pop()
        return urlEnd + 1
    }

    private fun isWordChar(text: String, index: Int): Boolean =
        index in text.indices && text[index].isLetterOrDigit()
}
