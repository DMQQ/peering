package pl.dmq.peering.feature.remote

/** What one edit of the soft keyboard's hidden field means to the Mac. */
sealed class SoftKeyboardEdit {
    data class Typed(val text: String) : SoftKeyboardEdit()

    data object Deleted : SoftKeyboardEdit()

    data object None : SoftKeyboardEdit()

    companion object {
        /** The field never sits empty, so a delete shows up as a change instead of nothing at all. */
        const val SENTINEL = " "

        /** Reads the field's new text. The field holds [SENTINEL] between edits, so text before it is not typed twice. */
        fun of(newText: String): SoftKeyboardEdit = when {
            newText.isEmpty() -> Deleted
            newText == SENTINEL -> None
            else -> newText.replace(SENTINEL, "").let { if (it.isEmpty()) None else Typed(it) }
        }
    }
}
