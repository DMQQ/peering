package pl.dmq.peering.feature.agents

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.agent.PromptTemplateStore
import pl.dmq.peering.session.ports.KeyValueStore

class PromptTemplatesPresenterTest {
    private class MemoryStore : KeyValueStore {
        val values = mutableMapOf<String, String>()
        var writes = 0

        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String) {
            writes++
            values[key] = value
        }
    }

    @Test
    fun aSavedPromptIsKeptAcrossARestart() {
        val store = MemoryStore()
        PromptTemplatesPresenter(PromptTemplateStore(store)).add("Summarise the diff")
        val reopened = PromptTemplatesPresenter(PromptTemplateStore(store))
        assertEquals(listOf("Summarise the diff"), reopened.templates.value.entries.map { it.text })
    }

    @Test
    fun savingABlankOrRepeatedPromptWritesNothing() {
        val store = MemoryStore()
        val presenter = PromptTemplatesPresenter(PromptTemplateStore(store))
        presenter.add("   ")
        presenter.add("One")
        presenter.add("One")
        assertEquals(1, store.writes)
    }

    @Test
    fun aRemovedPromptStaysGone() {
        val store = MemoryStore()
        val presenter = PromptTemplatesPresenter(PromptTemplateStore(store))
        presenter.add("One")
        presenter.remove(presenter.templates.value.entries.single().id)
        assertEquals(emptyList<String>(), PromptTemplatesPresenter(PromptTemplateStore(store)).templates.value.entries.map { it.text })
    }
}
