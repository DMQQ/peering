package pl.dmq.peering.feature.settings

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsSearchTest {
    private val keywords = "session controls interaction picture fit fill keyboard"

    @Test
    fun anEmptyQueryMatchesEveryCard() {
        assertTrue(SettingsSearch.matches(keywords, ""))
        assertTrue(SettingsSearch.matches(keywords, "   "))
    }

    @Test
    fun everyWordMustBeFound() {
        assertTrue(SettingsSearch.matches(keywords, "keyboard fill"))
        assertFalse(SettingsSearch.matches(keywords, "keyboard relay"))
    }

    @Test
    fun caseDoesNotMatter() {
        assertTrue(SettingsSearch.matches(keywords, "KEYBOARD"))
    }
}
