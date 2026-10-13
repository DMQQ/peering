package pl.dmq.peering.feature.agents

import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownRendererTest {
    private fun styledRanges(source: String) = MarkdownRenderer.render(source).spanStyles

    @Test
    fun plainTextIsKeptAsTyped() {
        assertEquals("hello there", MarkdownRenderer.render("hello there").text)
    }

    @Test
    fun paragraphsAreSeparatedByABlankLine() {
        assertEquals("first\n\nsecond", MarkdownRenderer.render("first\n\nsecond").text)
    }

    @Test
    fun singleLineBreaksInsideAParagraphAreKept() {
        assertEquals("line one\nline two", MarkdownRenderer.render("line one\nline two").text)
    }

    @Test
    fun boldAndItalicMarkersAreRemovedAndStyled() {
        val rendered = MarkdownRenderer.render("a **bold** and *slant*")
        assertEquals("a bold and slant", rendered.text)
        assertEquals(FontWeight.Bold, rendered.spanStyles.single { it.start == 2 }.item.fontWeight)
        assertEquals(FontStyle.Italic, rendered.spanStyles.single { it.start == 11 }.item.fontStyle)
    }

    @Test
    fun underscoreItalicsWorkButNotInsideAWord() {
        assertEquals("slant", MarkdownRenderer.render("_slant_").text)
        assertEquals("snake_case_name", MarkdownRenderer.render("snake_case_name").text)
    }

    @Test
    fun inlineCodeIsMonospaceWithoutItsBackticks() {
        val rendered = MarkdownRenderer.render("run `ls -la` now")
        assertEquals("run ls -la now", rendered.text)
        assertEquals(FontFamily.Monospace, rendered.spanStyles.single().item.fontFamily)
    }

    @Test
    fun formattingInsideCodeIsNotInterpreted() {
        assertEquals("**not bold**", MarkdownRenderer.render("`**not bold**`").text)
    }

    @Test
    fun unmatchedMarkersStayAsTyped() {
        assertEquals("5 * 3 and **open", MarkdownRenderer.render("5 * 3 and **open").text)
        assertTrue(styledRanges("5 * 3 and **open").isEmpty())
    }

    @Test
    fun codeFenceKeepsItsLinesVerbatimInMonospace() {
        val rendered = MarkdownRenderer.render("Before\n```kotlin\nval x = **1**\n```\nAfter")
        assertEquals("Before\n\nval x = **1**\n\nAfter", rendered.text)
        val code = rendered.spanStyles.single { it.item.fontFamily == FontFamily.Monospace }
        assertEquals("val x = **1**", rendered.text.substring(code.start, code.end))
    }

    @Test
    fun anUnclosedFenceStillShowsItsLines() {
        assertEquals("code here", MarkdownRenderer.render("```\ncode here").text)
    }

    @Test
    fun bulletItemsAreMarkedAndStackedWithoutBlankLines() {
        assertEquals("• one\n• two", MarkdownRenderer.render("- one\n* two").text)
    }

    @Test
    fun numberedItemsKeepTheirNumbers() {
        assertEquals("1. first\n2. second", MarkdownRenderer.render("1. first\n2) second").text)
    }

    @Test
    fun aListFollowedByParagraphIsSeparatedByABlankLine() {
        assertEquals("• item\n\nafter", MarkdownRenderer.render("- item\n\nafter").text)
    }

    @Test
    fun headingIsBoldWithoutItsHashes() {
        val rendered = MarkdownRenderer.render("## Plan")
        assertEquals("Plan", rendered.text)
        assertEquals(FontWeight.Bold, rendered.spanStyles.single().item.fontWeight)
    }

    @Test
    fun httpLinkIsTappableAndKeepsItsLabel() {
        val rendered = MarkdownRenderer.render("see [the docs](https://example.com/a) now")
        assertEquals("see the docs now", rendered.text)
        val link = rendered.getLinkAnnotations(4, 12).single().item as androidx.compose.ui.text.LinkAnnotation.Url
        assertEquals("https://example.com/a", link.url)
    }

    @Test
    fun linksWithOtherSchemesAreLeftAsText() {
        val source = "[run](javascript:alert(1))"
        val rendered = MarkdownRenderer.render(source)
        assertEquals(source, rendered.text)
        assertTrue(rendered.getLinkAnnotations(0, rendered.length).isEmpty())
    }
}
