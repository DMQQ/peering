package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Phone-shaped screens stop growing at [max] and sit centred on a wide window, so a tablet shows a column rather than a stretched page. */
@Composable
fun ReadableWidth(modifier: Modifier = Modifier, max: Dp = 560.dp, content: @Composable BoxScope.() -> Unit) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Box(Modifier.widthIn(max = max).fillMaxSize(), content = content)
    }
}
