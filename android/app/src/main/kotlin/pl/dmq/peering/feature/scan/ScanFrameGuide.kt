package pl.dmq.peering.feature.scan

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/** The square a code is held inside. The camera reads the whole frame; the square only says where to aim. */
@Composable
internal fun ScanFrameGuide(modifier: Modifier = Modifier) {
    Canvas(modifier.fillMaxSize()) {
        val side = size.minDimension * GUIDE_SHARE
        drawRoundRect(
            color = PeeringColors.ink,
            topLeft = Offset((size.width - side) / 2f, (size.height - side) / 2f),
            size = Size(side, side),
            cornerRadius = CornerRadius(CORNER.toPx()),
            style = Stroke(width = STROKE.toPx()),
        )
    }
}

private const val GUIDE_SHARE = 0.7f
private val CORNER = 24.dp
private val STROKE = 3.dp
