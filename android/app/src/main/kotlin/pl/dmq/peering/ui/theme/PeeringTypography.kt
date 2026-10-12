package pl.dmq.peering.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** Fixed-size text styles for the places that size text by hand. The body face is the system sans. */
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

    /** The display face at [size]. */
    fun display(size: Float, tracking: Float = 0f, lineHeight: Float = size * 1.08f) = TextStyle(
        fontFamily = displayFamily,
        fontWeight = FontWeight.Bold,
        fontSize = size.sp,
        lineHeight = lineHeight.sp,
        letterSpacing = tracking.sp,
    )
}

val wordmarkStyle = PeeringText.display(size = 60f, tracking = -2.2f)

/** Material's type scale: the serif carries display, headline and large titles; everything else is the system sans. */
val peeringTypography = Typography(
    displayLarge = PeeringText.display(size = 57f, tracking = -2f, lineHeight = 62f),
    displayMedium = PeeringText.display(size = 45f, tracking = -1.6f, lineHeight = 50f),
    displaySmall = PeeringText.display(size = 36f, tracking = -1.2f, lineHeight = 42f),
    headlineLarge = PeeringText.display(size = 34f, tracking = -1.2f, lineHeight = 40f),
    headlineMedium = PeeringText.display(size = 28f, tracking = -0.8f, lineHeight = 34f),
    headlineSmall = PeeringText.display(size = 24f, tracking = -0.5f, lineHeight = 30f),
    titleLarge = PeeringText.display(size = 22f, tracking = -0.3f, lineHeight = 28f),
    titleMedium = TextStyle(fontSize = 16.sp, lineHeight = 24.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.15.sp),
    titleSmall = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.1.sp),
    bodyLarge = TextStyle(fontSize = 16.sp, lineHeight = 24.sp, fontWeight = FontWeight.Normal, letterSpacing = 0.5.sp),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Normal, letterSpacing = 0.25.sp),
    bodySmall = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Normal, letterSpacing = 0.4.sp),
    labelLarge = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.1.sp),
    labelMedium = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.5.sp),
    labelSmall = TextStyle(fontSize = 11.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.5.sp),
)
