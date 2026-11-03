package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Test

class DictatedTextTest {
    @Test
    fun heardWordsFollowTypedTextAfterASpace() = assertEquals("Fix the bug please", DictatedText.joined("Fix the bug", " please "))

    @Test
    fun anEmptyPromptTakesTheWordsAsTheyAre() = assertEquals("hello", DictatedText.joined("", "hello"))

    @Test
    fun typedTextEndingInWhitespaceGetsNoSecondSpace() = assertEquals("a\nb", DictatedText.joined("a\n", "b"))

    @Test
    fun nothingHeardLeavesThePromptAlone() = assertEquals("draft ", DictatedText.joined("draft ", "  "))
}
