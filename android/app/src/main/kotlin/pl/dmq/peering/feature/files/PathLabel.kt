package pl.dmq.peering.feature.files

/** A path cut from the front so the folder the user is in stays visible, as the iPhone truncates it at the head. */
fun headTruncated(path: String, limit: Int = LOCATION_LIMIT): String {
    if (path.length <= limit) return path
    val tail = path.takeLast(limit - 1)
    val boundary = tail.indexOf('/')
    return "…" + if (boundary in 1 until tail.length - 1) tail.substring(boundary) else tail
}

private const val LOCATION_LIMIT = 36
