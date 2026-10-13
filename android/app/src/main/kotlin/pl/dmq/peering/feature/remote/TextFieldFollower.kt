package pl.dmq.peering.feature.remote

/** What the keyboard should do when the computer's focus moves. */
enum class KeyboardMove { OPEN, CLOSE, NONE }

/**
 * Opens the phone's keyboard when the computer focuses a text field, and closes it again when the focus leaves, but only
 * a keyboard it opened itself: one the person raised by hand stays until they put it away. Not thread safe.
 */
class TextFieldFollower {
    private var openedByFocus = false

    /** Which move a focus report asks for, given what the screen is doing. [keyboardShown] is read before the move. */
    fun onFocus(
        editable: Boolean,
        enabled: Boolean,
        observing: Boolean,
        mosaic: Boolean,
        panelOpen: Boolean,
        keyboardShown: Boolean,
    ): KeyboardMove {
        if (!enabled || observing || mosaic || panelOpen) {
            if (!keyboardShown) openedByFocus = false
            return KeyboardMove.NONE
        }
        if (editable) {
            if (keyboardShown) return KeyboardMove.NONE
            openedByFocus = true
            return KeyboardMove.OPEN
        }
        if (!openedByFocus) return KeyboardMove.NONE
        openedByFocus = false
        return KeyboardMove.CLOSE
    }

    /** The person put the keyboard away or raised it themselves, so it is theirs now. */
    fun keyboardToggledByHand() {
        openedByFocus = false
    }
}

/**
 * Holds the text the computer's field reported until the person has stopped typing, so the line they are typing does not
 * jump back to an older state of the field. A report that arrives while they type waits; a newer one replaces it.
 */
class FieldMirror(private val settleMillis: Long = SETTLE_MILLIS) {
    private var lastEditAt: Long? = null
    private var pending: String? = null

    fun onLocalEdit(nowMillis: Long) {
        lastEditAt = nowMillis
    }

    /** Takes in a report. Returns the text to show now, or null when it must wait for [waitMillis]. */
    fun onReport(text: String?, nowMillis: Long): String? {
        pending = text ?: return null
        return release(nowMillis)
    }

    /** How long until the held report may be shown, or null when none is held. */
    fun waitMillis(nowMillis: Long): Long? {
        if (pending == null) return null
        val since = lastEditAt?.let { nowMillis - it } ?: settleMillis
        return (settleMillis - since).coerceAtLeast(0)
    }

    /** The held report once the person has been still long enough, else null. */
    fun release(nowMillis: Long): String? {
        val text = pending ?: return null
        if (waitMillis(nowMillis) != 0L) return null
        pending = null
        return text
    }

    /** The focus moved: whatever was held described another field. */
    fun reset() {
        pending = null
    }

    companion object {
        const val SETTLE_MILLIS = 800L
    }
}
