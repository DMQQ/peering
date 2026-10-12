package pl.dmq.peering.feature.terminal

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import pl.dmq.peering.session.ports.KeyValueStore
import java.util.UUID

/** A line the user types often. An empty [title] shows the first word of the [command]. */
data class QuickCommand(val id: String = UUID.randomUUID().toString(), val title: String, val command: String) {
    val displayTitle: String
        get() = title.trim().ifEmpty { command.trim().substringBefore(' ').ifEmpty { "Command" } }
}

/** One command per line, fields split by a tab; backslash, tab and newline are escaped inside a field. */
internal object QuickCommandCodec {
    fun encode(commands: List<QuickCommand>): String =
        commands.joinToString("\n") { listOf(it.id, it.title, it.command).joinToString("\t", transform = ::escape) }

    fun decode(text: String): List<QuickCommand> = text.lines().mapNotNull { line ->
        val fields = line.split('\t').map(::unescape)
        if (fields.size == 3) QuickCommand(fields[0], fields[1], fields[2]) else null
    }

    private fun escape(field: String) = field.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")

    private fun unescape(field: String): String {
        val out = StringBuilder()
        var index = 0
        while (index < field.length) {
            val char = field[index]
            if (char == '\\' && index + 1 < field.length) {
                index++
                out.append(
                    when (field[index]) {
                        't' -> '\t'
                        'n' -> '\n'
                        else -> field[index]
                    },
                )
            } else {
                out.append(char)
            }
            index++
        }
        return out.toString()
    }
}

/** The saved quick commands, kept whole in one preference. */
class QuickCommands(private val store: KeyValueStore) {
    private val current = MutableStateFlow(store.read(KEY)?.let(QuickCommandCodec::decode).orEmpty())
    val all: StateFlow<List<QuickCommand>> = current.asStateFlow()

    /** Replaces the command with the same id, or appends a new one. */
    fun save(command: QuickCommand) = change { list ->
        if (list.any { it.id == command.id }) list.map { if (it.id == command.id) command else it } else list + command
    }

    fun delete(command: QuickCommand) = change { list -> list.filterNot { it.id == command.id } }

    private fun change(edit: (List<QuickCommand>) -> List<QuickCommand>) {
        current.update(edit)
        store.write(KEY, QuickCommandCodec.encode(current.value))
    }

    private companion object {
        const val KEY = "terminal_quick_commands"
    }
}
