package pl.dmq.peering.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringBackdrop

/** One legal document as text in the app. Documents with a web page also link to it, opened outside the app. */
@Composable
fun LegalPageScreen(
    document: LegalDocument,
    onOpenWebPage: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .peeringBackdrop()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = stringResource(document.labelRes()),
            style = MaterialTheme.typography.headlineSmall,
            color = PeeringColors.ink,
        )
        Text(
            text = stringResource(document.bodyRes()),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.ink,
        )
        document.webUrl()?.let { url ->
            Button(
                onClick = { onOpenWebPage(url) },
                colors = ButtonDefaults.buttonColors(containerColor = PeeringColors.ink, contentColor = PeeringColors.onInk),
            ) {
                Text(stringResource(R.string.legal_read_online), style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}
