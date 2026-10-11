package pl.dmq.peering.wire

private const val HEX_DIGITS = "0123456789abcdef"

/** Lowercase hexadecimal, two digits per byte. */
fun ByteArray.toHex(): String = buildString(size * 2) {
    for (byte in this@toHex) {
        val value = byte.toInt() and 0xFF
        append(HEX_DIGITS[value ushr 4])
        append(HEX_DIGITS[value and 0x0F])
    }
}

/** Decodes hexadecimal text in either case. Throws [IllegalArgumentException] for odd length or a non-hex digit. */
fun String.hexToBytes(): ByteArray {
    require(length % 2 == 0) { "hex text has an odd length" }
    return ByteArray(length / 2) { index ->
        val high = hexDigitValue(this[index * 2])
        val low = hexDigitValue(this[index * 2 + 1])
        ((high shl 4) or low).toByte()
    }
}

private fun hexDigitValue(char: Char): Int = when (char) {
    in '0'..'9' -> char - '0'
    in 'a'..'f' -> char - 'a' + 10
    in 'A'..'F' -> char - 'A' + 10
    else -> throw IllegalArgumentException("not a hex digit: $char")
}
