package pl.dmq.peering.feature.agents

import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
fun MarkdownText(source: String, modifier: Modifier = Modifier) {
    val rendered = remember(source) { MarkdownRenderer.render(source) }
    Text(
        text = rendered,
        modifier = modifier,
        style = MaterialTheme.typography.bodyLarge,
        color = PeeringColors.ink,
    )
}
