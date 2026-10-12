package pl.dmq.peering.feature.files

import java.util.Locale

/** A byte count as the iPhone words it: decimal units (1 KB is 1000 bytes), as `ByteCountFormatter` in file style. */
data class FileSize(val amount: Double, val unit: SizeUnit) {
    enum class SizeUnit(val suffix: String, val fractionDigits: Int) {
        BYTES("bytes", 0),
        KILOBYTES("KB", 0),
        MEGABYTES("MB", 1),
        GIGABYTES("GB", 2),
    }

    /** "Zero bytes", "1 byte", "704 bytes", "12 KB", "1.2 MB", "1.07 GB"; a figure that rounds to a whole number drops its decimals. */
    fun label(): String {
        if (unit == SizeUnit.BYTES) {
            return when (amount.toLong()) {
                0L -> "Zero bytes"
                1L -> "1 byte"
                else -> "${amount.toLong()} bytes"
            }
        }
        val text = String.format(Locale.US, "%.${unit.fractionDigits}f", amount)
        val trimmed = if (text.contains('.')) text.trimEnd('0').trimEnd('.') else text
        return "$trimmed ${unit.suffix}"
    }

    companion object {
        private const val STEP = 1000.0

        fun of(bytes: Long): FileSize {
            val value = bytes.coerceAtLeast(0).toDouble()
            return when {
                value < STEP -> FileSize(value, SizeUnit.BYTES)
                value < STEP * STEP -> FileSize(value / STEP, SizeUnit.KILOBYTES)
                value < STEP * STEP * STEP -> FileSize(value / (STEP * STEP), SizeUnit.MEGABYTES)
                else -> FileSize(value / (STEP * STEP * STEP), SizeUnit.GIGABYTES)
            }
        }
    }
}
