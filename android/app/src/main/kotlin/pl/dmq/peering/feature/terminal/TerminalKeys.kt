package pl.dmq.peering.feature.terminal

/** The keys the extra row offers because a soft keyboard has none of them. */
enum class ExtraKey { ESCAPE, TAB, UP, DOWN, LEFT, RIGHT, PIPE, TILDE }

/** What a shell expects for a key or a run of typed text. */
object TerminalKeys {
    const val ESC = 0x1B
    const val DELETE = 0x7F
    const val RETURN = 0x0D

    fun bytes(key: ExtraKey, alt: Boolean = false): ByteArray {
        val sequence = when (key) {
            ExtraKey.ESCAPE -> "\u001B"
            ExtraKey.TAB -> "\t"
            ExtraKey.UP -> "\u001B[A"
            ExtraKey.DOWN -> "\u001B[B"
            ExtraKey.RIGHT -> "\u001B[C"
            ExtraKey.LEFT -> "\u001B[D"
            ExtraKey.PIPE -> "|"
            ExtraKey.TILDE -> "~"
        }
        return withAlt(sequence.toByteArray(Charsets.UTF_8), alt && key != ExtraKey.ESCAPE)
    }

    /**
     * Typed text as bytes. A held Ctrl turns the first character into its control code and Alt sends Escape before
     * it; the rest of the run is untouched. A newline becomes a carriage return, which is what Enter sends.
     */
    fun bytes(text: String, ctrl: Boolean = false, alt: Boolean = false): ByteArray {
        if (text.isEmpty()) return ByteArray(0)
        val normalised = text.replace("\r\n", "\r").replace('\n', '\r')
        val first = normalised.codePointAt(0)
        val rest = normalised.substring(Character.charCount(first))
        val head = if (ctrl) controlCode(first)?.let { byteArrayOf(it.toByte()) } else null
        val lead = head ?: String(Character.toChars(first)).toByteArray(Charsets.UTF_8)
        return withAlt(lead, alt) + rest.toByteArray(Charsets.UTF_8)
    }

    fun controlCode(codePoint: Int): Int? = when (codePoint) {
        in 'a'.code..'z'.code -> codePoint - 'a'.code + 1
        in '@'.code..'_'.code -> codePoint - '@'.code
        ' '.code -> 0
        '?'.code -> DELETE
        else -> null
    }

    private fun withAlt(bytes: ByteArray, alt: Boolean): ByteArray = if (alt) byteArrayOf(ESC.toByte()) + bytes else bytes
}
