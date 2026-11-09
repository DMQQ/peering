package pl.dmq.peering.feature.files

/** Which way the folder list slides in: from the right going deeper, from the left going back. */
internal object FolderSlide {
    const val DURATION_MS = 280

    /** The list is half faded while it is away from rest, so the move reads as one list arriving rather than two crossing. */
    const val MOVING_ALPHA = 0.5f

    fun depth(path: String?): Int = path?.split('/')?.count { it.isNotEmpty() } ?: 0

    /** Where the list starts, as a signed distance from rest: positive begins on the right. Same depth counts as deeper, a sibling folder. */
    fun startOffset(from: String?, to: String?, widthPx: Float): Float = if (depth(to) >= depth(from)) widthPx else -widthPx
}
