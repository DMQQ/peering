package pl.dmq.peering.feature.remote

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.wire.Modifiers

/** A key press with modifiers that one button sends. [keyCode] is a macOS virtual keycode. */
data class Macro(val id: String, val title: String, val keyCode: Int, val modifiers: Long)

object Macros {
    private const val CMD = Modifiers.COMMAND
    private const val CTRL = Modifiers.CONTROL

    /** The set every session has, ahead of the macros the user adds. */
    val defaults: List<Macro> = listOf(
        Macro("copy", "⌘C", 8, CMD),
        Macro("paste", "⌘V", 9, CMD),
        Macro("cut", "⌘X", 7, CMD),
        Macro("undo", "⌘Z", 6, CMD),
        Macro("save", "⌘S", 1, CMD),
        Macro("close", "⌘W", 13, CMD),
        Macro("appswitch", "⌘⇥", 48, CMD),
        Macro("spotlight", "⌘Space", 49, CMD),
        Macro("escape", "esc", 53, 0L),
        Macro("return", "⏎", 36, 0L),
        Macro("ctrl-c", "⌃C", 8, CTRL),
        Macro("ctrl-z", "⌃Z", 6, CTRL),
        Macro("ctrl-d", "⌃D", 2, CTRL),
        Macro("ctrl-l", "⌃L", 37, CTRL),
        Macro("ctrl-a", "⌃A", 0, CTRL),
        Macro("ctrl-e", "⌃E", 14, CTRL),
        Macro("ctrl-r", "⌃R", 15, CTRL),
    )

    /** The button's mark when the user gave no label: the modifiers in the Mac's order, then the key. */
    fun autoTitle(key: MacroKey, modifiers: Long): String = buildString {
        if (modifiers and Modifiers.CONTROL != 0L) append('⌃')
        if (modifiers and Modifiers.OPTION != 0L) append('⌥')
        if (modifiers and Modifiers.SHIFT != 0L) append('⇧')
        if (modifiers and Modifiers.COMMAND != 0L) append('⌘')
        append(key.label)
    }
}

/** A key the macro editor offers. */
data class MacroKey(val id: String, val label: String, val keyCode: Int)

object MacroKeys {
    private val letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { letter ->
        MacroKey(letter.lowercase(), letter.toString(), macKeyForCharacter(letter.code) ?: 0)
    }

    private val named = listOf(
        MacroKey("return", "Return", 36),
        MacroKey("escape", "Escape", 53),
        MacroKey("tab", "Tab", 48),
        MacroKey("space", "Space", 49),
        MacroKey("delete", "Delete", 51),
        MacroKey("fwddel", "Fwd Del", 117),
        MacroKey("home", "Home", 115),
        MacroKey("end", "End", 119),
        MacroKey("pageup", "Page Up", 116),
        MacroKey("pagedown", "Page Down", 121),
        MacroKey("up", "↑", 126),
        MacroKey("down", "↓", 125),
        MacroKey("left", "←", 123),
        MacroKey("right", "→", 124),
    )

    private val functionKeys = FunctionKey.entries.map { MacroKey(it.name.lowercase(), it.name, it.macKeyCode) }

    val popular: List<MacroKey> = letters + named + functionKeys
}

/** The macros the user added, kept across launches. */
interface MacroStore {
    val custom: StateFlow<List<Macro>>

    /** False when the macro did not persist. */
    fun add(macro: Macro): Boolean

    fun remove(id: String): Boolean
}

/** Stores macros as one line each, so a stored list survives a release that adds a field at the end. */
object MacroCodec {
    private const val FIELD = '\u001F'

    fun encode(macros: List<Macro>): String =
        macros.joinToString("\n") { listOf(it.id, it.title.replace("\n", " "), it.keyCode, it.modifiers).joinToString(FIELD.toString()) }

    /** Lines that cannot be read are dropped, so one bad entry does not cost the rest. */
    fun decode(text: String): List<Macro> = text.lines().mapNotNull { line ->
        val parts = line.split(FIELD)
        val keyCode = parts.getOrNull(2)?.toIntOrNull()
        val modifiers = parts.getOrNull(3)?.toLongOrNull()
        if (parts.size < 4 || keyCode == null || modifiers == null) null else Macro(parts[0], parts[1], keyCode, modifiers)
    }
}
