package pl.dmq.peering.wire

sealed class KeyRoute {
    /** A printable character, sent as text so the host types it for the active layout. */
    data class Text(val codepoint: Int) : KeyRoute()

    data class Key(val macKeyCode: Int, val modifiers: Long) : KeyRoute()

    /** A key with no macOS equivalent and no character: it is not sent. */
    data object Ignored : KeyRoute()
}

/** Android KeyEvent keycode to macOS virtual keycode. Keys absent here (Insert, media keys) are not sent. */
fun macKeyCode(androidKeyCode: Int): Int? = ANDROID_TO_MAC[androidKeyCode]

/**
 * Printable characters without Ctrl, Alt or Meta go as text. Everything else goes as a key, with the modifiers
 * carried by [metaState]. Unknown meta state counts as no modifiers.
 */
fun routeKey(unicodeChar: Int, androidKeyCode: Int, metaState: Long?): KeyRoute {
    val meta = metaState ?: 0L
    val modifiers = modifiersFor(meta)
    if (isPrintable(unicodeChar) && (meta and ANDROID_META_TEXT_BLOCKERS) == 0L) return KeyRoute.Text(unicodeChar)
    val mac = macKeyCode(androidKeyCode) ?: return KeyRoute.Ignored
    return KeyRoute.Key(mac, modifiers)
}

private const val ANDROID_META_SHIFT_ON = 0x1L
private const val ANDROID_META_ALT_ON = 0x2L
private const val ANDROID_META_CTRL_ON = 0x1000L
private const val ANDROID_META_META_ON = 0x10000L
private const val ANDROID_META_TEXT_BLOCKERS = ANDROID_META_ALT_ON or ANDROID_META_CTRL_ON or ANDROID_META_META_ON

private val ANDROID_META_TO_MODIFIER: List<Pair<Long, Long>> = listOf(
    ANDROID_META_SHIFT_ON to Modifiers.SHIFT,
    ANDROID_META_CTRL_ON to Modifiers.CONTROL,
    ANDROID_META_ALT_ON to Modifiers.OPTION,
    ANDROID_META_META_ON to Modifiers.COMMAND,
)

private fun modifiersFor(meta: Long): Long =
    ANDROID_META_TO_MODIFIER.fold(0L) { bits, (androidBit, macBit) ->
        if ((meta and androidBit) != 0L) bits or macBit else bits
    }

private fun isPrintable(codepoint: Int): Boolean =
    Character.isValidCodePoint(codepoint) && !Character.isISOControl(codepoint)

private val ANDROID_TO_MAC: Map<Int, Int> = mapOf(
    7 to 29, 8 to 18, 9 to 19, 10 to 20, 11 to 21, 12 to 23,
    13 to 22, 14 to 26, 15 to 28, 16 to 25, 19 to 126, 20 to 125,
    21 to 123, 22 to 124, 29 to 0, 30 to 11, 31 to 8, 32 to 2,
    33 to 14, 34 to 3, 35 to 5, 36 to 4, 37 to 34, 38 to 38,
    39 to 40, 40 to 37, 41 to 46, 42 to 45, 43 to 31, 44 to 35,
    45 to 12, 46 to 15, 47 to 1, 48 to 17, 49 to 32, 50 to 9,
    51 to 13, 52 to 7, 53 to 16, 54 to 6, 55 to 43, 56 to 47,
    57 to 58, 58 to 61, 59 to 56, 60 to 60, 61 to 48, 62 to 49,
    66 to 36, 67 to 51, 68 to 50, 69 to 27, 70 to 24, 71 to 33,
    72 to 30, 73 to 42, 74 to 41, 75 to 39, 76 to 44, 92 to 116,
    93 to 121, 111 to 53, 112 to 117, 113 to 59, 114 to 62, 115 to 57,
    117 to 55, 118 to 54, 122 to 115, 123 to 119, 131 to 122, 132 to 120,
    133 to 99, 134 to 118, 135 to 96, 136 to 97, 137 to 98, 138 to 100,
    139 to 101, 140 to 109, 141 to 103, 142 to 111,
)
