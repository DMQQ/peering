package pl.dmq.peering.feature.remote

import pl.dmq.peering.feature.sessionmode.TypedDiff

/** Reads the soft keyboard's hidden field, which is reset to [SENTINEL] after every committed edit. */
object SoftKeyboardEdit {
    /**
     * Keeps the field from sitting empty, so a delete still changes it. A zero-width space, not a plain one: a plain
     * space could not be told apart from a typed space, and Gboard turns two spaces into ". ".
     */
    const val SENTINEL = "​"

    /** What changed between the field as last shown and as the keyboard left it, the sentinel counting as a character. */
    fun between(shown: String, next: String): TypedDiff = TypedDiff.of(shown, next).let { diff ->
        TypedDiff(diff.appended.replace(SENTINEL, ""), diff.deleted)
    }
}
