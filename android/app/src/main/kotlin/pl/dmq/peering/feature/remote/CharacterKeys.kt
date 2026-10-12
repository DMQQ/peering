package pl.dmq.peering.feature.remote

private val CHARACTER_KEYS: Map<Char, Int> = mapOf(
    'a' to 0, 'b' to 11, 'c' to 8, 'd' to 2, 'e' to 14, 'f' to 3, 'g' to 5, 'h' to 4, 'i' to 34,
    'j' to 38, 'k' to 40, 'l' to 37, 'm' to 46, 'n' to 45, 'o' to 31, 'p' to 35, 'q' to 12, 'r' to 15,
    's' to 1, 't' to 17, 'u' to 32, 'v' to 9, 'w' to 13, 'x' to 7, 'y' to 16, 'z' to 6,
    '0' to 29, '1' to 18, '2' to 19, '3' to 20, '4' to 21, '5' to 23, '6' to 22, '7' to 26, '8' to 28, '9' to 25,
)

/**
 * The macOS keycode that types an ASCII letter (either case) or digit on a US layout, so a latched modifier can be
 * held while it is pressed. Null for anything else, which must travel as text.
 */
fun macKeyForCharacter(codepoint: Int): Int? {
    if (codepoint !in 0..0x7F) return null
    return CHARACTER_KEYS[Character.toLowerCase(codepoint).toChar()]
}
