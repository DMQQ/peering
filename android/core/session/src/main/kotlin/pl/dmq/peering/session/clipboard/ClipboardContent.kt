package pl.dmq.peering.session.clipboard

/** Something one clipboard holds: text, or a picture as PNG bytes. */
sealed interface ClipboardContent {
    data class Text(val text: String) : ClipboardContent

    class Image(val png: ByteArray) : ClipboardContent {
        override fun equals(other: Any?): Boolean = this === other || (other is Image && png.contentEquals(other.png))

        override fun hashCode(): Int = png.contentHashCode()
    }
}

enum class ClipboardDirection { FROM_COMPUTER, TO_COMPUTER }

/** One line of the clipboard history. [atMillis] is Unix time in milliseconds. */
class ClipboardEntry(
    val id: Long,
    val content: ClipboardContent,
    val atMillis: Long,
    val direction: ClipboardDirection,
)

/** Why a picture was or was not sent to the computer. */
sealed interface ClipboardPush {
    data object Sent : ClipboardPush

    data object NotReady : ClipboardPush

    /** The computer did not declare that it takes pictures. */
    data object Unsupported : ClipboardPush

    data class TooLarge(val bytes: Int) : ClipboardPush
}
