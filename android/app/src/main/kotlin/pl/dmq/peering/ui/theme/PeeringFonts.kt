package pl.dmq.peering.ui.theme

import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import pl.dmq.peering.R

/** The display face, for names only: the wordmark and a screen's title. The iPhone sets the same job in a bold serif. */
@OptIn(ExperimentalTextApi::class)
val displayFamily = FontFamily(
    Font(
        resId = R.font.source_serif_4,
        weight = FontWeight.Bold,
        variationSettings = FontVariation.Settings(
            FontVariation.weight(FontWeight.Bold.weight),
            FontVariation.Setting("opsz", DISPLAY_OPTICAL_SIZE),
        ),
    ),
)

private const val DISPLAY_OPTICAL_SIZE = 48f
