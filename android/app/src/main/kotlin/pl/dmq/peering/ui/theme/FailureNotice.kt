package pl.dmq.peering.ui.theme

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R

/** A failure in words, with a Details expander for the exception text when there is any. */
@Composable
fun FailureNotice(message: String, details: String?, modifier: Modifier = Modifier) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    Column(
        modifier = modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(message, style = MaterialTheme.typography.bodyLarge, color = PeeringColors.danger, textAlign = TextAlign.Center)
        if (details != null) {
            TextButton(onClick = { expanded = !expanded }) {
                Text(stringResource(R.string.failure_details), color = PeeringColors.muted)
            }
            if (expanded) {
                Text(details, style = MaterialTheme.typography.bodySmall, color = PeeringColors.faint, textAlign = TextAlign.Center)
            }
        }
    }
}
