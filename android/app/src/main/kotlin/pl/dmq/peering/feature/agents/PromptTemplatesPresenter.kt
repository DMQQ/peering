package pl.dmq.peering.feature.agents

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.session.agent.PromptTemplateStore
import pl.dmq.peering.session.agent.PromptTemplates

/** The person's own prompts, offered under the built-in suggestions in an empty chat. */
class PromptTemplatesPresenter(private val store: PromptTemplateStore) {
    private val state = MutableStateFlow(store.load())

    val templates: StateFlow<PromptTemplates> = state.asStateFlow()

    fun add(text: String) = change(state.value.add(text))

    fun remove(id: String) = change(state.value.remove(id))

    private fun change(next: PromptTemplates) {
        if (next == state.value) return
        state.value = next
        store.save(next)
    }
}
