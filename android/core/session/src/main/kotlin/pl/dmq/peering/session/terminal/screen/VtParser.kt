package pl.dmq.peering.session.terminal.screen

/** The byte-level state machine of [VtScreen]: plain text, escape sequences, and strings that are skipped. */
internal class VtParser(private val screen: VtScreen) {
    private enum class State { GROUND, ESCAPE, CSI, STRING, DISCARD }

    private var state = State.GROUND

    /** Raw until the final byte says what they mean: the `?` of `CSI ?1049h` must stay recognisable. */
    private val parameters = ByteArray(PARAMETER_LIMIT)
    private var count = 0
    private val utf8 = Utf8Accumulator()

    fun consume(byte: Int) {
        when (state) {
            State.GROUND -> ground(byte)
            State.ESCAPE -> escape(byte)
            State.CSI -> csi(byte)
            State.STRING -> when (byte) {
                BELL -> state = State.GROUND
                ESC -> state = State.DISCARD
            }
            State.DISCARD -> state = State.GROUND
        }
    }

    private fun ground(byte: Int) {
        when {
            byte == ESC -> state = State.ESCAPE
            byte < 0x20 || byte == 0x7F -> screen.control(byte)
            else -> utf8.append(byte)?.let { if (it !in C1_CONTROLS) screen.put(it) }
        }
    }

    private fun escape(byte: Int) {
        state = when (byte.toChar()) {
            '\u001B' -> State.ESCAPE
            '[' -> {
                count = 0
                State.CSI
            }
            ']', 'P', '^', '_' -> State.STRING
            '(', ')', '*', '+', '-', '.', '/' -> State.DISCARD
            else -> State.GROUND
        }
    }

    private fun csi(byte: Int) {
        when (byte) {
            in 0x40..0x7E -> {
                apply(byte)
                state = State.GROUND
            }
            in 0x30..0x3F -> if (count < PARAMETER_LIMIT) parameters[count++] = byte.toByte()
            in 0x20..0x2F -> Unit
            else -> {
                // A control byte or a buffer cut mid-escape ends the sequence and is handled as itself.
                state = State.GROUND
                consume(byte)
            }
        }
    }

    private fun apply(final: Int) {
        val row = screen.row
        val column = screen.column
        when (final.toChar()) {
            'A' -> screen.place(row - offset(0), column)
            'B', 'e' -> screen.place(row + offset(0), column)
            'C', 'a' -> screen.place(row, column + offset(0))
            'D' -> screen.place(row, column - offset(0))
            'E' -> screen.place(row + offset(0), 0)
            'F' -> screen.place(row - offset(0), 0)
            'G', '`' -> screen.place(row, offset(0) - 1)
            'd' -> screen.place(offset(0) - 1, column)
            'H', 'f' -> screen.place(offset(0) - 1, offset(1) - 1)
            'J' -> screen.eraseDisplay(number(0, 0))
            'K' -> screen.eraseLine(number(0, 0))
            'm' -> screen.attributes = SgrParser.apply(parameters, count, screen.attributes)
            'h', 'l' -> if (count > 0 && parameters[0] == QUESTION) setModes(final == 'h'.code)
        }
    }

    /** The alternate screen is the one mode honoured, and only private: `CSI 1049h` is not `CSI ?1049h`. */
    private fun setModes(enabled: Boolean) {
        for (index in 0 until MODE_LIMIT) {
            val code = number(index, -1)
            if (code < 0) return
            if (code == 47 || code == 1047 || code == 1049) screen.alternateScreen(enabled)
        }
    }

    /** Anything that is not a digit ends the number, keeping the `?` out; clamped as it accumulates. */
    private fun number(index: Int, fallback: Int): Int {
        var field = 0
        var value = 0
        var digits = false
        for (position in 0 until count) {
            val byte = parameters[position].toInt()
            when {
                byte in 0x30..0x39 -> {
                    value = minOf(value * 10 + (byte - 0x30), SgrParser.CEILING)
                    digits = true
                }
                byte == SEMICOLON -> {
                    if (field == index) return if (digits) value else fallback
                    field += 1
                    value = 0
                    digits = false
                }
            }
        }
        return if (field == index && digits) value else fallback
    }

    /** One-based; missing, unreadable or zero reads as one, so `CSI 0 A` equals `CSI A`. */
    private fun offset(index: Int): Int = maxOf(1, number(index, 1))

    private companion object {
        const val ESC = 0x1B
        const val BELL = 0x07
        const val SEMICOLON = 0x3B
        const val QUESTION = 0x3F.toByte()
        const val PARAMETER_LIMIT = 32
        const val MODE_LIMIT = 8
        val C1_CONTROLS = 0x80..0x9F
    }
}
