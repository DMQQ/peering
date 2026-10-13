package pl.dmq.peering.feature.terminal

import org.junit.Assert.assertEquals
import org.junit.Test

class CommandHighlightTest {
    private fun spans(text: String) = CommandHighlight.spans(text).map { Triple(it.kind, it.start, it.end) }

    @Test
    fun plainWordsAreNotColoured() {
        assertEquals(emptyList<Any>(), spans("git status"))
    }

    @Test
    fun aFlagIsColouredToTheEndOfTheWord() {
        assertEquals(listOf(Triple(HighlightKind.FLAG, 3, 6)), spans("ls -la"))
    }

    @Test
    fun aQuotedStringKeepsItsQuotesAndEscapes() {
        assertEquals(listOf(Triple(HighlightKind.QUOTED, 5, 13)), spans("echo \"a \\\" b\" x"))
        assertEquals(listOf(Triple(HighlightKind.QUOTED, 5, 9)), spans("echo 'hi'"))
    }

    @Test
    fun anUnclosedQuoteRunsToTheEnd() {
        assertEquals(listOf(Triple(HighlightKind.QUOTED, 5, 9)), spans("echo \"abc"))
    }

    @Test
    fun doubledOperatorsAreOneSpan() {
        assertEquals(listOf(Triple(HighlightKind.OPERATOR, 2, 4)), spans("a && b"))
        assertEquals(listOf(Triple(HighlightKind.OPERATOR, 2, 4)), spans("a >> b"))
        assertEquals(listOf(Triple(HighlightKind.OPERATOR, 2, 3)), spans("a | b"))
    }

    @Test
    fun variablesTakeTheirNameOrTheirBraces() {
        assertEquals(listOf(Triple(HighlightKind.VARIABLE, 5, 10)), spans("echo \$HOME x"))
        assertEquals(listOf(Triple(HighlightKind.VARIABLE, 5, 12)), spans("echo \${A:-b}"))
    }
}
