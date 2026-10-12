package pl.dmq.peering.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** The iPhone's text styles at its default size, named as UIKit names them. The body face is the system sans (SF is not licensed for Android). */
object PeeringText {
    val body = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.Normal)
    val headline = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
    val title3 = TextStyle(fontSize = 20.sp, lineHeight = 25.sp, fontWeight = FontWeight.Normal)
    val subheadline = TextStyle(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.Normal)
    val subheadlineMedium = subheadline.copy(fontWeight = FontWeight.Medium)
    val subheadlineSemibold = subheadline.copy(fontWeight = FontWeight.SemiBold)
    val footnote = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal)
    val footnoteMedium = footnote.copy(fontWeight = FontWeight.Medium)
    val caption = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Normal)
    val captionSemibold = caption.copy(fontWeight = FontWeight.SemiBold)
    val caption2 = TextStyle(fontSize = 11.sp, lineHeight = 13.sp, fontWeight = FontWeight.Normal)
    val caption2Monospaced = caption2.copy(fontFamily = FontFamily.Monospace)

    /** The display face at [size], tracked as the iPhone tracks it. */
    fun display(size: Float, tracking: Float = 0f, lineHeight: Float = size * 1.08f) = TextStyle(
        fontFamily = displayFamily,
        fontWeight = FontWeight.Bold,
        fontSize = size.sp,
        lineHeight = lineHeight.sp,
        letterSpacing = tracking.sp,
    )
}

val wordmarkStyle = PeeringText.display(size = 60f, tracking = -2.2f)

val peeringTypography = Typography(
    headlineLarge = PeeringText.display(size = 34f, tracking = -1.2f, lineHeight = 40f),
    headlineMedium = PeeringText.display(size = 28f, tracking = -0.8f, lineHeight = 34f),
    headlineSmall = PeeringText.display(size = 26f, tracking = -0.6f, lineHeight = 32f),
    titleMedium = PeeringText.subheadlineSemibold,
    titleSmall = PeeringText.subheadlineMedium,
    bodyLarge = PeeringText.body,
    bodyMedium = PeeringText.subheadline,
    bodySmall = PeeringText.footnote,
    labelLarge = PeeringText.subheadlineSemibold,
    labelMedium = PeeringText.captionSemibold.copy(letterSpacing = 0.2.sp),
    labelSmall = PeeringText.caption2.copy(fontWeight = FontWeight.Medium),
)
