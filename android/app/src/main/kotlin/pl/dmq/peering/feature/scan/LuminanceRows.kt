package pl.dmq.peering.feature.scan

/** Copies the [width] bytes of each row out of a plane whose rows are [rowStride] bytes apart, top row first. */
internal fun compactLuminanceRows(plane: ByteArray, rowStride: Int, width: Int, height: Int): ByteArray {
    require(rowStride >= width && width > 0 && height > 0) { "a row stride smaller than the width cannot hold the plane" }
    val compact = ByteArray(width * height)
    for (row in 0 until height) {
        val from = row * rowStride
        val available = (plane.size - from).coerceAtMost(width)
        if (available <= 0) break
        plane.copyInto(compact, destinationOffset = row * width, startIndex = from, endIndex = from + available)
    }
    return compact
}
