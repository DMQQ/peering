package pl.dmq.peering.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringBackdrop

/** What stands in front of the app until the device's own unlock has been answered. */
@Composable
internal fun LockScreen(onUnlock: () -> Unit) {
    Column(
        Modifier.fillMaxSize().peeringBackdrop().padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Image(painterResource(R.drawable.pears), contentDescription = null, modifier = Modifier.size(96.dp))
        Text(stringResource(R.string.connect_unlock_title), style = MaterialTheme.typography.headlineMedium, color = PeeringColors.ink)
        PrimaryButton(stringResource(R.string.connect_unlock), onClick = onUnlock, modifier = Modifier.widthIn(max = 320.dp))
    }
}
