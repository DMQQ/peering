package pl.dmq.peering.feature.terminal

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import pl.dmq.peering.ui.theme.PeeringColors

enum class HighlightKind { QUOTED, OPERATOR, VARIABLE, FLAG }

data class HighlightSpan(val start: Int, val end: Int, val kind: HighlightKind)

/** The syntax colouring of the command line: quoted text, shell operators, variables and flags. */
object CommandHighlight {
    private const val OPERATORS = "|;&><()"
    private const val WORD_BREAKS = "\"'|;&><$()"

    fun spans(text: String): List<HighlightSpan> {
        val spans = ArrayList<HighlightSpan>()
        var i = 0
        while (i < text.length) {
            val c = text[i]
            i = when {
                c == '"' || c == '\'' -> quoted(text, i).also { spans += HighlightSpan(i, it, HighlightKind.QUOTED) }
                c in OPERATORS -> operator(text, i).also { spans += HighlightSpan(i, it, HighlightKind.OPERATOR) }
                c == '$' -> variable(text, i).also { spans += HighlightSpan(i, it, HighlightKind.VARIABLE) }
                !c.isWhitespace() -> word(text, i).also { if (text[i] == '-') spans += HighlightSpan(i, it, HighlightKind.FLAG) }
                else -> i + 1
            }
        }
        return spans
    }

    private fun quoted(text: String, start: Int): Int {
        val quote = text[start]
        var i = start + 1
        while (i < text.length && text[i] != quote) i += if (text[i] == '\\') 2 else 1
        return minOf(i + 1, text.length)
    }

    private fun operator(text: String, start: Int): Int {
        val next = text.getOrNull(start + 1)
        val doubled = next == text[start] || (text[start] == '>' && next == '>')
        return if (next != null && doubled) start + 2 else start + 1
    }

    private fun variable(text: String, start: Int): Int {
        var i = start + 1
        if (text.getOrNull(i) == '{') {
            while (i < text.length && text[i] != '}') i++
            return minOf(i + 1, text.length)
        }
        while (i < text.length && (text[i].isLetterOrDigit() || text[i] == '_')) i++
        return i
    }

    private fun word(text: String, start: Int): Int {
        var i = start
        while (i < text.length && !text[i].isWhitespace() && text[i] !in WORD_BREAKS) i++
        return maxOf(i, start + 1)
    }
}

private fun HighlightKind.style(): SpanStyle = SpanStyle(
    color = when (this) {
        HighlightKind.QUOTED -> PeeringColors.caution
        HighlightKind.OPERATOR -> PeeringColors.accent
        HighlightKind.VARIABLE -> Color.White.copy(alpha = 0.65f)
        HighlightKind.FLAG -> Color.White.copy(alpha = 0.50f)
    },
)

/** Colours the field's text without changing it, so the cursor and the keyboard see the same string. */
object CommandHighlightTransformation : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val coloured = buildAnnotatedString {
            append(text.text)
            CommandHighlight.spans(text.text).forEach { addStyle(it.kind.style(), it.start, it.end) }
        }
        return TransformedText(coloured, OffsetMapping.Identity)
    }
}
