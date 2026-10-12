package pl.dmq.peering.session.agent

import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import pl.dmq.peering.session.ports.KeyValueStore

@Serializable
data class PromptTemplate(val id: String, val text: String)

/** Prompts the person saved to start a chat with, kept on this phone beside the built-in suggestions. Newest first. */
@Serializable
data class PromptTemplates(val entries: List<PromptTemplate> = emptyList()) {
    /** Blank text and a prompt already saved leave the list as it was; the oldest gives way at the limit. */
    fun add(text: String, id: String = UUID.randomUUID().toString()): PromptTemplates {
        val trimmed = text.trim().take(MAXIMUM_LENGTH)
        if (trimmed.isEmpty() || entries.any { it.text == trimmed }) return this
        return PromptTemplates((listOf(PromptTemplate(id, trimmed)) + entries).take(MAXIMUM_COUNT))
    }

    fun remove(id: String): PromptTemplates = PromptTemplates(entries.filterNot { it.id == id })

    companion object {
        const val MAXIMUM_COUNT = 12
        const val MAXIMUM_LENGTH = 500
    }
}

/** The saved prompts as one value in the phone's key-value store. A value that cannot be read is treated as none saved. */
class PromptTemplateStore(private val store: KeyValueStore, private val key: String = KEY) {
    fun load(): PromptTemplates {
        val raw = store.read(key) ?: return PromptTemplates()
        return runCatching { Json.decodeFromString<PromptTemplates>(raw) }.getOrDefault(PromptTemplates())
    }

    fun save(templates: PromptTemplates) = store.write(key, Json.encodeToString(PromptTemplates.serializer(), templates))

    private companion object {
        const val KEY = "agent_prompt_templates"
    }
}
