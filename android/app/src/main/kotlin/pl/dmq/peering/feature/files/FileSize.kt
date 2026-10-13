package pl.dmq.peering.feature.files

import java.text.NumberFormat
import java.util.Locale

/** A byte count as the iPhone words it: decimal units (1 KB is 1000 bytes), as `ByteCountFormatter` in file style. */
data class FileSize(val amount: Double, val unit: SizeUnit) {
    enum class SizeUnit(val suffix: String, val fractionDigits: Int) {
        BYTES("B", 0),
        KILOBYTES("KB", 0),
        MEGABYTES("MB", 1),
        GIGABYTES("GB", 2),
    }

    /** "0 B", "704 B", "12 KB", "1.2 MB", "1.07 GB" with the locale's separator; a figure that rounds to a whole number drops its decimals. */
    fun label(): String {
        val format = NumberFormat.getNumberInstance(Locale.getDefault()).apply {
            minimumFractionDigits = 0
            maximumFractionDigits = unit.fractionDigits
        }
        return "${format.format(amount)} ${unit.suffix}"
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
