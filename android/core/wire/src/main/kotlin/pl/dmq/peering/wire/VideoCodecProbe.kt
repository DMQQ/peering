package pl.dmq.peering.wire

/**
 * Maps the decoder MIME types a phone reports onto the codec names the host sends. Order is the preference: HEVC
 * first when it is decodable, since the host chooses it by default.
 */
object VideoCodecProbe {
    private val preference: List<Pair<String, String>> = listOf(
        "video/hevc" to "hevc",
        "video/avc" to "h264",
    )

    fun codecPreference(supportedMimeTypes: Collection<String>): List<String> {
        val supported = supportedMimeTypes.mapTo(HashSet()) { it.lowercase() }
        return preference.filter { (mimeType, _) -> mimeType in supported }.map { (_, codec) -> codec }
    }
}
