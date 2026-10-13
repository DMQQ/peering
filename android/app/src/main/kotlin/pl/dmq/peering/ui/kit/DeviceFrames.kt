package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** The tour's phone, from the marketing site's mockup: every measure is a fraction of the screen width. */
object PhoneMetrics {
    const val ASPECT = 603f / 1311f
    const val BEZEL = 10f / 290f
    const val BODY_CORNER = 0.148f
    const val SCREEN_CORNER = 0.128f
    val rim = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.30f), Color.White.copy(alpha = 0.08f)))

    fun bodyWidth(screenWidth: Dp) = screenWidth * (1 + 2 * BEZEL)
    fun bodyHeight(screenWidth: Dp) = screenWidth / ASPECT + screenWidth * 2 * BEZEL
}

/** A black phone with the island drawn on, holding [screen] (a picture, cropped to fill). */
@Composable
fun PhoneDrawing(screenWidth: Dp, modifier: Modifier = Modifier, screen: @Composable () -> Unit) {
    val screenHeight = screenWidth / PhoneMetrics.ASPECT
    val bezel = screenWidth * PhoneMetrics.BEZEL
    val body = RoundedCornerShape(PhoneMetrics.bodyWidth(screenWidth) * PhoneMetrics.BODY_CORNER)
    Box(
        modifier = modifier
            .size(PhoneMetrics.bodyWidth(screenWidth), PhoneMetrics.bodyHeight(screenWidth))
            .shadow(22.dp, body, ambientColor = Color.Black, spotColor = Color.Black)
            .background(Color.Black, body)
            .border(1.dp, PhoneMetrics.rim, body),
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(screenWidth, screenHeight).clip(RoundedCornerShape(screenWidth * PhoneMetrics.SCREEN_CORNER))) {
            screen()
            Box(
                Modifier
                    .align(Alignment.TopCenter)
                    .offset(y = screenHeight * 0.019f)
                    .size(screenWidth * 0.30f, screenHeight * 0.038f)
                    .background(Color.Black, CircleShape),
            )
        }
        Box(Modifier.size(bezel))
    }
}

object MacMetrics {
    const val ASPECT = 1512f / 982f
    const val BEZEL = 0.017f
    const val LID_CORNER = 0.030f
    const val LID_LOWER_CORNER = 0.009f
    const val BASE_HEIGHT = 0.030f
    const val BASE_OVERHANG = 1.055f
    const val NOTCH_WIDTH = 0.092f
    const val NOTCH_HEIGHT = 0.026f
}

/** The Mac's frame: a black lid around [screen] and a graphite base with a scoop, sized by the display's width. */
@Composable
fun MacDrawing(displayWidth: Dp, modifier: Modifier = Modifier, screen: @Composable () -> Unit) {
    val displayHeight = displayWidth / MacMetrics.ASPECT
    val bezel = displayWidth * MacMetrics.BEZEL
    val lidWidth = displayWidth + bezel * 2
    val lidHeight = displayHeight + bezel * 2
    val baseHeight = lidWidth * MacMetrics.BASE_HEIGHT
    val baseWidth = lidWidth * MacMetrics.BASE_OVERHANG
    val lid = RoundedCornerShape(
        topStart = lidWidth * MacMetrics.LID_CORNER, topEnd = lidWidth * MacMetrics.LID_CORNER,
        bottomStart = lidWidth * MacMetrics.LID_LOWER_CORNER, bottomEnd = lidWidth * MacMetrics.LID_LOWER_CORNER,
    )
    val base = RoundedCornerShape(bottomStart = baseHeight * 0.36f, bottomEnd = baseHeight * 0.36f)
    Column(
        modifier = modifier.shadow(26.dp, lid, ambientColor = Color.Black, spotColor = Color.Black),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.size(lidWidth, lidHeight).background(Color.Black, lid).border(1.dp, PhoneMetrics.rim, lid),
            contentAlignment = Alignment.Center,
        ) {
            Box(Modifier.size(displayWidth, displayHeight).clip(RoundedCornerShape(lidWidth * MacMetrics.LID_CORNER - bezel))) {
                screen()
                Box(
                    Modifier
                        .align(Alignment.TopCenter)
                        .size(displayWidth * MacMetrics.NOTCH_WIDTH, displayHeight * MacMetrics.NOTCH_HEIGHT)
                        .background(Color.Black, RoundedCornerShape(bottomStart = displayHeight * 0.013f, bottomEnd = displayHeight * 0.013f)),
                )
            }
        }
        Box(
            Modifier
                .size(baseWidth, baseHeight)
                .background(Brush.verticalGradient(listOf(Color(0xFF1C1C1F), Color(0xFF0B0B0D))), base),
            contentAlignment = Alignment.TopCenter,
        ) {
            Box(Modifier.size(baseWidth * 0.15f, baseHeight * 0.55f).background(Color(0xFF060607), CircleShape))
        }
    }
}
