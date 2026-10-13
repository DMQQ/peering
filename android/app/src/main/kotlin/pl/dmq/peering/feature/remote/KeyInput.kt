package pl.dmq.peering.feature.remote

/** One hardware or soft keyboard event, with the Android fields that decide what it means. */
data class KeyInput(
    val androidKeyCode: Int,
    val unicodeChar: Int,
    val metaState: Long,
    val isDown: Boolean,
)
