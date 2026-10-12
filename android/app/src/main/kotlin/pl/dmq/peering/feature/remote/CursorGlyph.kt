package pl.dmq.peering.feature.remote

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import pl.dmq.peering.wire.NormalizedPoint

/**
 * The pointer drawn over the picture where the computer's pointer is, a white arrow with a dark outline whose tip sits on
 * the point. [picture] is the picture's rectangle as drawn, so the glyph follows zoom and pan without growing with them.
 */
@Composable
fun CursorGlyph(position: NormalizedPoint, picture: CanvasRect, modifier: Modifier = Modifier) {
    Canvas(modifier.fillMaxSize()) {
        val size = CURSOR_SIZE.toPx()
        val tip = Offset((picture.left + position.x * picture.width).toFloat(), (picture.top + position.y * picture.height).toFloat())
        val path = Path().apply {
            ARROW.forEachIndexed { index, (x, y) ->
                val point = Offset(tip.x + x * size, tip.y + y * size)
                if (index == 0) moveTo(point.x, point.y) else lineTo(point.x, point.y)
            }
            close()
        }
        drawPath(path, Color.Black, style = Stroke(width = size * OUTLINE, join = StrokeJoin.Round))
        drawPath(path, Color.White, style = Fill)
    }
}

private val CURSOR_SIZE = 24.dp
private const val OUTLINE = 0.1f

private val ARROW = listOf(
    0.000f to 0.000f,
    0.000f to 0.707f,
    0.201f to 0.512f,
    0.390f to 0.963f,
    0.549f to 0.896f,
    0.360f to 0.445f,
    0.622f to 0.445f,
)
