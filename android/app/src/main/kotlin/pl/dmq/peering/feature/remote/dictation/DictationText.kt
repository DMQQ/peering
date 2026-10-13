package pl.dmq.peering.feature.remote.dictation

/** How spoken text joins what is already typed. */
object DictationText {
    /** The text to type for [spoken] after [existing]: trimmed, and separated from a word before it by one space. */
    fun insertion(existing: String, spoken: String): String {
        val trimmed = spoken.trim()
        if (trimmed.isEmpty()) return ""
        val last = existing.lastOrNull()
        return if (last == null || last.isWhitespace()) trimmed else " $trimmed"
    }
}
