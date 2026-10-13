package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.Modifiers

/** A key chord one button sends: the chord is the mark on the button and [label] the word under it. [confirms] asks first. */
data class QuickAction(
    val id: String,
    val chord: String,
    val label: String,
    val keyCode: Int,
    val modifiers: Long,
    val confirms: Boolean = false,
)

/** The edit chords the dock and the landscape rail always offer. Quit can lose unsaved work, so it asks first. */
object QuickActions {
    val defaults: List<QuickAction> = listOf(
        QuickAction("copy", "⌘C", "Copy", keyCode = 8, modifiers = Modifiers.COMMAND),
        QuickAction("paste", "⌘V", "Paste", keyCode = 9, modifiers = Modifiers.COMMAND),
        QuickAction("undo", "⌘Z", "Undo", keyCode = 6, modifiers = Modifiers.COMMAND),
        QuickAction("cut", "⌘X", "Cut", keyCode = 7, modifiers = Modifiers.COMMAND),
        QuickAction("quit", "⌘Q", "Quit", keyCode = 12, modifiers = Modifiers.COMMAND, confirms = true),
    )
}
