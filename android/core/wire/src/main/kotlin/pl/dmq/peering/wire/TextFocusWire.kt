package pl.dmq.peering.wire

import kotlinx.serialization.Serializable

/** The computer's keyboard focus moved to or from a text field. Sent only to a client that declared it reads this. */
@Serializable
data class TextFocusPayload(val isEditable: Boolean)

/**
 * What the focused text field on the computer holds and where its insertion point is. [text] is absent for a field the
 * computer could not read, such as a password. Selection counts are UTF-16 units, as the computer's strings count them.
 */
@Serializable
data class FieldStatePayload(
    val text: String? = null,
    val selectionLocation: Int = 0,
    val selectionLength: Int = 0,
    val caret: NormalizedPoint? = null,
) {
    /** The selection as a field here can take it: the numbers arrive from the computer, and a range outside the text throws. */
    fun selectionIn(length: Int): IntRange {
        val start = selectionLocation.coerceIn(0, length)
        val end = (start + selectionLength.coerceAtLeast(0)).coerceAtMost(length)
        return start until end.coerceAtLeast(start)
    }

    fun clamped(): FieldStatePayload = copy(caret = caret?.clamped())
}
