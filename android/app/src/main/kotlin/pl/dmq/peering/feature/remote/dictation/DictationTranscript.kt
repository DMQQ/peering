package pl.dmq.peering.feature.remote.dictation

/**
 * What has been heard in one dictation. The recogniser ends a phrase on a pause, so the finished phrases are kept and the
 * one in progress follows them.
 */
data class DictationTranscript(private val finished: List<String> = emptyList(), private val partial: String = "") {
    val text: String get() = (finished + partial).map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" ")

    fun withPartial(words: String) = copy(partial = words)

    /** The phrase is final; a blank result keeps the partial words, since a recogniser may end on silence after speaking. */
    fun withFinished(words: String): DictationTranscript = DictationTranscript(finished + words.ifBlank { partial }, partial = "")
}
