package pl.dmq.peering.feature.files

/** A byte count split into the figure and the unit the screen shows it in. */
data class FileSize(val amount: Double, val unit: SizeUnit) {
    enum class SizeUnit { BYTES, KILOBYTES, MEGABYTES, GIGABYTES }

    companion object {
        private const val KILO = 1024.0

        fun of(bytes: Long): FileSize {
            val value = bytes.coerceAtLeast(0).toDouble()
            return when {
                value < KILO -> FileSize(value, SizeUnit.BYTES)
                value < KILO * KILO -> FileSize(value / KILO, SizeUnit.KILOBYTES)
                value < KILO * KILO * KILO -> FileSize(value / (KILO * KILO), SizeUnit.MEGABYTES)
                else -> FileSize(value / (KILO * KILO * KILO), SizeUnit.GIGABYTES)
            }
        }
    }
}
