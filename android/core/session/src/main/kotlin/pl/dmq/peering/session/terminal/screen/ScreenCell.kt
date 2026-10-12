package pl.dmq.peering.session.terminal.screen

/** The rendition a cell was written with; never consulted as the current one beyond the next write. */
internal data class CellAttributes(
    val foreground: TerminalColor = TerminalColor.Default,
    val background: TerminalColor = TerminalColor.Default,
    val bold: Boolean = false,
    val dim: Boolean = false,
)

internal data class ScreenCell(val codePoint: Int = SPACE, val attributes: CellAttributes = CellAttributes()) {
    /** An uncoloured space. A coloured blank is a bar and stays; bold or dim is not visible on a blank. */
    val isBlank: Boolean
        get() = codePoint == SPACE &&
            attributes.foreground == TerminalColor.Default &&
            attributes.background == TerminalColor.Default

    companion object {
        const val SPACE = ' '.code
        val BLANK = ScreenCell()
    }
}

/** Survives a character split across two reads. */
internal class Utf8Accumulator {
    private val pending = ByteArray(4)
    private var count = 0

    /** The code point once complete, [REPLACEMENT] for a malformed one, or null while more bytes are due. */
    fun append(byte: Int): Int? {
        if (count == 0 && byte < 0x80) return byte
        pending[count++] = byte.toByte()
        if (count < lengthOf(pending[0].toInt() and 0xFF)) return null
        val text = String(pending, 0, count, Charsets.UTF_8)
        count = 0
        return if (text.codePointCount(0, text.length) == 1) text.codePointAt(0) else REPLACEMENT
    }

    /** A byte that cannot start a sequence claims one, so a stray continuation byte is consumed rather than stalling. */
    private fun lengthOf(lead: Int): Int = when (lead) {
        in 0xC0..0xDF -> 2
        in 0xE0..0xEF -> 3
        in 0xF0..0xF7 -> 4
        else -> 1
    }

    companion object {
        const val REPLACEMENT = 0xFFFD
    }
}
