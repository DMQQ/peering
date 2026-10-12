package pl.dmq.peering.feature.terminal

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.session.ports.KeyValueStore

/** One start of an agent from the list page. */
data class AgentLaunch(val agentID: String, val atMillis: Long, val computer: String)

/** The starts, newest first and capped, kept whole in one preference: a line per start, fields split by a tab. */
class AgentLaunchHistory(private val store: KeyValueStore) {
    private val current = MutableStateFlow(store.read(KEY)?.let(::decode).orEmpty())
    val all: StateFlow<List<AgentLaunch>> = current.asStateFlow()

    fun record(launch: AgentLaunch) = change { listOf(launch) + it }

    fun clear() = change { emptyList() }

    fun lastUsedMillis(agentID: String): Long? = current.value.firstOrNull { it.agentID == agentID }?.atMillis

    private fun change(edit: (List<AgentLaunch>) -> List<AgentLaunch>) {
        current.value = edit(current.value).sortedByDescending { it.atMillis }.take(LIMIT)
        store.write(KEY, current.value.joinToString("\n") { "${it.agentID}\t${it.atMillis}\t${clean(it.computer)}" })
    }

    private fun clean(text: String) = text.replace('\t', ' ').replace('\n', ' ')

    private fun decode(text: String): List<AgentLaunch> = text.lines().mapNotNull { line ->
        val fields = line.split('\t')
        val at = fields.getOrNull(1)?.toLongOrNull()
        if (fields.size == 3 && at != null) AgentLaunch(fields[0], at, fields[2]) else null
    }

    private companion object {
        const val KEY = "terminal_agent_history"
        const val LIMIT = 50
    }
}
