package pl.dmq.peering.ui.theme

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/** A tab's title in the display face, with a one-line detail in the system face (a sentence in the display face reads as a second title). */
@Composable
fun ScreenHeader(title: String, modifier: Modifier = Modifier, detail: String? = null) {
    Column(modifier = modifier.semantics { heading() }) {
        Text(text = title, style = MaterialTheme.typography.headlineLarge, color = PeeringColors.ink)
        if (detail != null) {
            Text(
                text = detail,
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.muted,
                modifier = Modifier.padding(top = 5.dp),
            )
        }
    }
}
