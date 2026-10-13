package pl.dmq.peering.feature.agents

/**
 * Whether the transcript follows new rows to the bottom. Scrolling away stops the following and remembers how many
 * rows were on screen, so the rows that arrive after are counted as unseen. Sending a prompt or jumping to the
 * latest row follows again.
 */
data class StickToBottom(
    val following: Boolean = true,
    val rowsSeen: Int = 0,
) {
    fun unseenRows(rowCount: Int): Int = if (following) 0 else (rowCount - rowsSeen).coerceAtLeast(0)

    fun userScrolled(atBottom: Boolean, rowCount: Int): StickToBottom = when {
        atBottom -> StickToBottom()
        following -> StickToBottom(following = false, rowsSeen = rowCount)
        else -> this
    }

    fun followLatest(): StickToBottom = StickToBottom()
}
