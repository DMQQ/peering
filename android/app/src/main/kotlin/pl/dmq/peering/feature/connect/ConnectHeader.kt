package pl.dmq.peering.feature.connect

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.arrive
import pl.dmq.peering.ui.theme.wordmarkStyle

/** The mark, the name and the pitch: the one screen that wears the brand at full size. */
@Composable
internal fun ConnectHeader(modifier: Modifier = Modifier) {
    Column(modifier = modifier.fillMaxWidth().padding(top = 12.dp)) {
        Image(
            painter = painterResource(R.drawable.peering_mark),
            contentDescription = null,
            modifier = Modifier.height(MARK_HEIGHT.dp).arrive(),
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = stringResource(R.string.app_name),
            style = wordmarkStyle,
            color = PeeringColors.ink.copy(alpha = 0.92f),
            modifier = Modifier.arrive(delayMillis = 70),
        )
        Text(
            text = stringResource(R.string.connect_tagline),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
            modifier = Modifier.arrive(delayMillis = 140),
        )
    }
}

private const val MARK_HEIGHT = 56
