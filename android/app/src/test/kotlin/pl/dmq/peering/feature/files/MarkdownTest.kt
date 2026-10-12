package pl.dmq.peering.feature.files

import org.junit.Assert.assertEquals
import org.junit.Test

class MarkdownTest {
    @Test
    fun headingsListsQuotesAndRulesBecomeBlocks() {
        val blocks = MarkdownBlocks.parse(
            """
            # Title

            Some text
            continues here.

            - one
              - nested
            2. two
            > quoted
            ---
            """.trimIndent(),
        )
        assertEquals(
            listOf(
                MarkdownBlock.Heading(1, "Title"),
                MarkdownBlock.Paragraph("Some text continues here."),
                MarkdownBlock.Bullet("one", 0),
                MarkdownBlock.Bullet("nested", 1),
                MarkdownBlock.Numbered(2, "two", 0),
                MarkdownBlock.Quote("quoted"),
                MarkdownBlock.Rule,
            ),
            blocks,
        )
    }

    @Test
    fun fencedCodeKeepsItsLinesAndIgnoresMarkdownInside() {
        val blocks = MarkdownBlocks.parse("before\n```kotlin\n# not a heading\nval x = 1\n```\nafter")
        assertEquals(
            listOf(
                MarkdownBlock.Paragraph("before"),
                MarkdownBlock.Code("# not a heading\nval x = 1"),
                MarkdownBlock.Paragraph("after"),
            ),
            blocks,
        )
    }

    @Test
    fun anUnclosedFenceStillShowsItsCode() {
        assertEquals(listOf<MarkdownBlock>(MarkdownBlock.Code("a\nb")), MarkdownBlocks.parse("```\na\nb"))
    }

    @Test
    fun inlineMarksSplitIntoStyledSpans() {
        assertEquals(
            listOf(
                MarkdownSpan("use ", MarkdownSpan.Style.PLAIN),
                MarkdownSpan("ls -l", MarkdownSpan.Style.CODE),
                MarkdownSpan(" and ", MarkdownSpan.Style.PLAIN),
                MarkdownSpan("both", MarkdownSpan.Style.BOLD),
                MarkdownSpan(" or ", MarkdownSpan.Style.PLAIN),
                MarkdownSpan("one", MarkdownSpan.Style.ITALIC),
            ),
            MarkdownSpans.parse("use `ls -l` and **both** or *one*"),
        )
    }

    @Test
    fun anUnclosedMarkStaysAsTyped() {
        assertEquals(listOf(MarkdownSpan("a **b", MarkdownSpan.Style.PLAIN)), MarkdownSpans.parse("a **b"))
    }
}
