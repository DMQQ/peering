package pl.dmq.peering.session.terminal.screen

/**
 * Select Graphic Rendition. Parameters are read as a list so an extended colour stays one colour: a reader taking
 * `38` alone would read the `5` of `38;5;208` as blink and shift everything after it.
 */
internal object SgrParser {
    const val CEILING = 9999
    private const val DIGIT_ZERO = 0x30
    private const val DIGIT_NINE = 0x39
    private const val SEMICOLON = 0x3B
    private const val COLON = 0x3A

    fun apply(parameters: ByteArray, count: Int, current: CellAttributes): CellAttributes {
        val fields = fields(parameters, count) ?: return current
        var attributes = current
        var index = 0
        while (index < fields.size) {
            val code = fields[index].firstOrNull() ?: 0
            index += 1
            attributes = when (code) {
                0 -> CellAttributes()
                1 -> attributes.copy(bold = true)
                2 -> attributes.copy(dim = true)
                22 -> attributes.copy(bold = false, dim = false)
                in 30..37 -> attributes.copy(foreground = TerminalColor.Indexed(code - 30))
                in 40..47 -> attributes.copy(background = TerminalColor.Indexed(code - 40))
                39 -> attributes.copy(foreground = TerminalColor.Default)
                49 -> attributes.copy(background = TerminalColor.Default)
                in 90..97 -> attributes.copy(foreground = TerminalColor.Indexed(code - 90 + 8))
                in 100..107 -> attributes.copy(background = TerminalColor.Indexed(code - 100 + 8))
                38, 48 -> {
                    val extended = extendedColour(fields, index - 1)
                    index += extended.consumed - 1
                    val colour = extended.colour
                    when {
                        colour == null -> attributes
                        code == 38 -> attributes.copy(foreground = colour)
                        else -> attributes.copy(background = colour)
                    }
                }
                else -> attributes
            }
        }
        return attributes
    }

    /**
     * `;` separates parameters and `:` sub-parameters. An empty field is zero, so a bare `CSI m` resets; anything
     * else (the `?` of a private mode) drops the sequence.
     */
    fun fields(parameters: ByteArray, count: Int): List<List<Int>>? {
        if (count == 0) return listOf(listOf(0))
        val fields = mutableListOf<List<Int>>()
        var field = mutableListOf<Int>()
        var value = 0
        var digits = false
        for (position in 0 until count) {
            val byte = parameters[position].toInt()
            when (byte) {
                in DIGIT_ZERO..DIGIT_NINE -> {
                    value = minOf(value * 10 + (byte - DIGIT_ZERO), CEILING)
                    digits = true
                }
                SEMICOLON, COLON -> {
                    field.add(if (digits) value else 0)
                    if (byte == SEMICOLON) {
                        fields.add(field)
                        field = mutableListOf()
                    }
                    value = 0
                    digits = false
                }
                else -> return null
            }
        }
        field.add(if (digits) value else 0)
        fields.add(field)
        return fields
    }

    class Extended(val consumed: Int, val colour: TerminalColor?)

    /** The colour a `38` or `48` names and how many parameters it took, returned even when it is not drawn. */
    fun extendedColour(fields: List<List<Int>>, start: Int): Extended {
        if (start >= fields.size) return Extended(1, null)
        val numbers = fields[start].toMutableList()
        var consumed = 1
        if (numbers.size == 1) {
            if (start + 1 >= fields.size || fields[start + 1].size != 1) return Extended(1, null)
            val total = when (fields[start + 1][0]) {
                2 -> 5
                5 -> 3
                else -> 0
            }
            if (total == 0) return Extended(1, null)
            while (numbers.size < total) {
                if (start + consumed >= fields.size || fields[start + consumed].size != 1) {
                    return Extended(consumed, null)
                }
                numbers.add(fields[start + consumed][0])
                consumed += 1
            }
        }
        return Extended(consumed, colourOf(numbers))
    }

    private fun colourOf(numbers: List<Int>): TerminalColor? {
        if (numbers.size < 2) return null
        return when (numbers[1]) {
            5 -> numbers.takeIf { it.size >= 3 }?.last()?.takeIf { it in 0..255 }?.let { TerminalColor.Indexed(it) }
            2 -> {
                if (numbers.size < 5) return null
                val parts = numbers.takeLast(3)
                if (parts.any { it !in 0..255 }) null else TerminalColor.Rgb(parts[0], parts[1], parts[2])
            }
            else -> null
        }
    }
}
