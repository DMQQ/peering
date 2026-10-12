package pl.dmq.peering.imaging

/** The most pixels a picture may have once decoded, which is 64 MB as ARGB_8888. */
internal const val MAX_DECODE_PIXELS = 16_000_000L

internal object ImageSampling {
    /** The power of two to pass as `inSampleSize` so that a [width] by [height] picture decodes to at most [maxPixels]. */
    fun sampleSize(width: Int, height: Int, maxPixels: Long = MAX_DECODE_PIXELS): Int {
        if (width <= 0 || height <= 0) return 1
        var sample = 1
        while ((width.toLong() / sample) * (height.toLong() / sample) > maxPixels) sample *= 2
        return sample
    }

    /** The largest power of two that still leaves the longer side of a picture at [edge] pixels or more. */
    fun sampleForEdge(width: Int, height: Int, edge: Int): Int {
        val longest = maxOf(width, height)
        if (longest <= 0) return 1
        var sample = 1
        while (longest / (sample * 2) >= edge) sample *= 2
        return sample
    }
}
