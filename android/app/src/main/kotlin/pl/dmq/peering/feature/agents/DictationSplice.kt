package pl.dmq.peering.feature.agents

import kotlin.math.abs

/**
 * Places a dictation's words into a field the person may keep typing in. The words go where the field ended when
 * listening started; each new transcript replaces only the words this splice put there, so text typed before or after
 * them stays. If the person edits inside the dictated words, their edit wins and later words go after it.
 */
class DictationSplice(text: String) {
    private var start = text.length
    private var inserted = ""
    private var heardBefore = 0

    /** [current] is the field now and [heard] the whole transcript so far; returns what the field should hold. */
    fun apply(current: String, heard: String): String {
        val at = locate(current)
        if (at < 0) {
            start = current.length
            inserted = ""
            heardBefore = heard.length
            return current
        }
        val before = current.substring(0, at)
        val words = heard.substring(minOf(heardBefore, heard.length))
        val segment = DictatedText.joined(before, words).substring(before.length)
        start = at
        val result = before + segment + current.substring(at + inserted.length)
        inserted = segment
        return result
    }

    /** Where this splice's words sit in [current], the occurrence nearest where they were last, or -1 when edited away. */
    private fun locate(current: String): Int {
        if (inserted.isEmpty()) return minOf(start, current.length)
        var best = -1
        var from = current.indexOf(inserted)
        while (from >= 0) {
            if (best < 0 || abs(from - start) < abs(best - start)) best = from
            from = current.indexOf(inserted, from + 1)
        }
        return best
    }
}
