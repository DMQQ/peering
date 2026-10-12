package pl.dmq.peering.feature.files

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R

@Composable
fun fileSizeLabel(bytes: Long): String {
    val size = FileSize.of(bytes)
    return when (size.unit) {
        FileSize.SizeUnit.BYTES -> stringResource(R.string.files_size_bytes, size.amount.toLong())
        FileSize.SizeUnit.KILOBYTES -> stringResource(R.string.files_size_kilobytes, formatOneDecimal(size.amount))
        FileSize.SizeUnit.MEGABYTES -> stringResource(R.string.files_size_megabytes, formatOneDecimal(size.amount))
        FileSize.SizeUnit.GIGABYTES -> stringResource(R.string.files_size_gigabytes, formatOneDecimal(size.amount))
    }
}

internal fun formatOneDecimal(value: Double): String = String.format(java.util.Locale.US, "%.1f", value)
