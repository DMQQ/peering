package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Material's circular progress indicator, sized for inline use. */
@Composable
fun PeeringSpinner(modifier: Modifier = Modifier, size: Dp = 20.dp, color: Color = Color.White) {
    CircularProgressIndicator(modifier = modifier.size(size), color = color, trackColor = Color.Transparent, strokeWidth = size / 9f)
}
