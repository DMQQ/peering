package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import pl.dmq.peering.session.ports.KeyValueStore

class PromptTemplatesTest {
    private class MemoryStore(val values: MutableMap<String, String> = mutableMapOf()) : KeyValueStore {
        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String) {
            values[key] = value
        }
    }

    @Test
    fun theNewestPromptComesFirst() {
        val templates = PromptTemplates().add("one", "1").add("two", "2")
        assertEquals(listOf("two", "one"), templates.entries.map { it.text })
    }

    @Test
    fun blankTextAndARepeatChangeNothing() {
        val templates = PromptTemplates().add("one", "1")
        assertSame(templates, templates.add("   "))
        assertSame(templates, templates.add(" one "))
    }

    @Test
    fun aLongPromptIsCutAtTheLimit() {
        val saved = PromptTemplates().add("x".repeat(PromptTemplates.MAXIMUM_LENGTH + 40))
        assertEquals(PromptTemplates.MAXIMUM_LENGTH, saved.entries.single().text.length)
    }

    @Test
    fun theOldestGivesWayAtTheLimit() {
        var templates = PromptTemplates()
        repeat(PromptTemplates.MAXIMUM_COUNT + 2) { templates = templates.add("prompt $it", "id$it") }
        assertEquals(PromptTemplates.MAXIMUM_COUNT, templates.entries.size)
        assertEquals("prompt ${PromptTemplates.MAXIMUM_COUNT + 1}", templates.entries.first().text)
        assertEquals("prompt 2", templates.entries.last().text)
    }

    @Test
    fun aPromptCanBeRemovedById() {
        val templates = PromptTemplates().add("one", "1").add("two", "2").remove("1")
        assertEquals(listOf("two"), templates.entries.map { it.text })
    }

    @Test
    fun savedPromptsComeBackAfterARestart() {
        val values = MemoryStore()
        PromptTemplateStore(values).save(PromptTemplates().add("one", "1").add("two", "2"))
        assertEquals(listOf("two", "one"), PromptTemplateStore(values).load().entries.map { it.text })
    }

    @Test
    fun anUnreadableValueMeansNothingSaved() {
        val values = MemoryStore(mutableMapOf("agent_prompt_templates" to "{not json"))
        assertEquals(PromptTemplates(), PromptTemplateStore(values).load())
        assertEquals(PromptTemplates(), PromptTemplateStore(MemoryStore()).load())
    }
}
