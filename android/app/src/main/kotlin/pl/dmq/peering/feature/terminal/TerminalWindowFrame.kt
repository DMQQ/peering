package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

private val windowOutline = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.20f), Color.White.copy(alpha = 0.06f)))

/** A shell drawn as a small window: radius 20, a 4 percent title strip, a hairline, then a darkened body. */
@Composable
fun TerminalWindowFrame(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val shape = peeringShapes.medium
    Column(Modifier.fillMaxWidth().clip(shape).then(modifier).border(1.dp, windowOutline, shape), content = content)
}

@Composable
fun TerminalWindowTitle(height: Dp, content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier.fillMaxWidth().height(height).background(Color.White.copy(alpha = 0.04f)).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
    HorizontalDivider(color = PeeringColors.hairline)
}

@Composable
fun TerminalWindowDots() {
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        repeat(3) { Box(Modifier.size(8.dp).background(Color.White.copy(alpha = 0.16f), CircleShape)) }
    }
}

@Composable
fun TerminalWindowBody(
    modifier: Modifier = Modifier,
    horizontal: Dp,
    vertical: Dp,
    contentMinHeight: Dp = 74.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.35f))
            .padding(horizontal = horizontal, vertical = vertical).heightIn(min = contentMinHeight),
        content = content,
    )
}
