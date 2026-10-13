package pl.dmq.peering.feature.scan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/** The square a code is held inside: the picture dims around it and four corners mark it. The camera reads the whole frame. */
@Composable
internal fun ScanFrameGuide(modifier: Modifier = Modifier) {
    Canvas(modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }) {
        val side = size.minDimension * GUIDE_SHARE
        val origin = Offset((size.width - side) / 2f, (size.height - side) / 2f)
        val radius = CORNER.toPx()
        drawRect(PeeringColors.backdrop.copy(alpha = 0.6f))
        drawRoundRect(Color.Black, origin, Size(side, side), CornerRadius(radius), blendMode = BlendMode.Clear)
        val arm = side * ARM_SHARE
        val corners = Path().apply {
            for ((dx, dy) in listOf(0 to 0, 1 to 0, 0 to 1, 1 to 1)) {
                val x = origin.x + dx * side
                val y = origin.y + dy * side
                val sx = if (dx == 0) 1 else -1
                val sy = if (dy == 0) 1 else -1
                moveTo(x, y + sy * arm)
                lineTo(x, y + sy * radius)
                quadraticTo(x, y, x + sx * radius, y)
                lineTo(x + sx * arm, y)
            }
        }
        drawPath(corners, PeeringColors.ink, style = Stroke(width = STROKE.toPx(), cap = StrokeCap.Round))
    }
}

private const val GUIDE_SHARE = 0.7f
private const val ARM_SHARE = 0.22f
private val CORNER = 24.dp
private val STROKE = 4.dp
