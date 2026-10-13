package pl.dmq.peering.wire

const val MAX_BITRATE_KBPS = 100_000

private const val MIN_DEFAULT_BITRATE_BPS = 4_000_000.0
private const val MAX_DEFAULT_BITRATE_BPS = 30_000_000.0
private const val BITS_PER_PIXEL_PER_FRAME = 0.12

/** Null for a request that is not a bitrate at all (zero or negative). Anything above the maximum is capped. */
fun clampedBitrateKbps(requested: Long): Int? {
    if (requested <= 0) return null
    return minOf(requested, MAX_BITRATE_KBPS.toLong()).toInt()
}

/** Scales with frame rate. A budget set too low arrives as a lower frame rate, since the encoder drops frames. */
fun defaultBitrateBps(width: Int, height: Int, fps: Int): Int {
    val raw = width.toDouble() * height * BITS_PER_PIXEL_PER_FRAME * fps
    return raw.coerceIn(MIN_DEFAULT_BITRATE_BPS, MAX_DEFAULT_BITRATE_BPS).toInt()
}

enum class QualityTier(val kbps: Int) {
    LOW(2_000),
    MEDIUM(8_000),
    HIGH(20_000),
    ;

    companion object {
        /** The highest tier not above [kbps], or null below the lowest tier. */
        fun fromKbps(kbps: Int): QualityTier? = entries.lastOrNull { it.kbps <= kbps }
    }
}

/**
 * Turns measurements into a stable tier. It falls on the first bad sample and climbs only after
 * [HEALTHY_SAMPLES_FOR_UPGRADE] good ones in a row, so one good ping cannot make the stream bounce. The ceiling caps the
 * climb and the start, never the fall.
 */
class AutoQualityPolicy(private val path: Path, private val ceiling: QualityTier = QualityTier.HIGH) {
    enum class Path { LAN, RELAY, DIRECT }

    var tier: QualityTier = minOf(if (path == Path.RELAY) QualityTier.MEDIUM else QualityTier.HIGH, ceiling)
        private set

    private var healthySamples = 0

    /** Returns the new tier only when the host should be told to change bitrate. */
    fun observe(latencyMilliseconds: Double, newDroppedFrames: Int): QualityTier? {
        if (latencyMilliseconds >= LOW_LATENCY_MS || newDroppedFrames >= LOW_DROPPED_FRAMES) {
            healthySamples = 0
            return change(QualityTier.LOW)
        }
        if (latencyMilliseconds >= SLOW_LATENCY_MS || newDroppedFrames > 0) {
            healthySamples = 0
            return change(tier.stepDown())
        }
        if (latencyMilliseconds > healthyLatencyMs()) {
            healthySamples = 0
            return null
        }
        healthySamples += 1
        if (healthySamples < HEALTHY_SAMPLES_FOR_UPGRADE) return null
        healthySamples = 0
        return change(tier.stepUp())
    }

    private fun change(proposed: QualityTier): QualityTier? {
        val capped = minOf(proposed, ceiling)
        if (capped == tier) return null
        tier = capped
        return capped
    }

    private fun healthyLatencyMs(): Double = if (path == Path.RELAY) 80.0 else 65.0

    private fun QualityTier.stepDown(): QualityTier = QualityTier.entries[maxOf(ordinal - 1, 0)]

    private fun QualityTier.stepUp(): QualityTier = QualityTier.entries[minOf(ordinal + 1, QualityTier.entries.lastIndex)]

    companion object {
        const val HEALTHY_SAMPLES_FOR_UPGRADE = 12
        private const val SLOW_LATENCY_MS = 160.0
        private const val LOW_LATENCY_MS = 350.0
        private const val LOW_DROPPED_FRAMES = 3
    }
}
