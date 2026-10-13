package pl.dmq.peering.feature.onboarding

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FaqEntriesTest {
    private val items = FaqEntries.sections.flatMap { it.items }

    @Test
    fun everySectionHasAtLeastOneQuestion() {
        assertTrue(FaqEntries.sections.isNotEmpty())
        assertTrue(FaqEntries.sections.all { it.items.isNotEmpty() })
    }

    @Test
    fun eachQuestionHasItsOwnAnswerAndNoQuestionRepeats() {
        assertTrue(items.all { it.questionRes != it.answerRes })
        assertEquals(items.size, items.map { it.questionRes }.toSet().size)
        assertEquals(items.size, items.map { it.answerRes }.toSet().size)
    }

    @Test
    fun sectionTitlesAreDistinct() {
        val titles = FaqEntries.sections.map { it.titleRes }
        assertEquals(titles.size, titles.toSet().size)
    }
}
