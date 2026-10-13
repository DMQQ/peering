package pl.dmq.peering.feature.whatsnew

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** Shows the current release once. It is recorded as seen the moment it appears, so a swipe away or a relaunch cannot bring it back. */
@Composable
fun WhatsNewHost(store: WhatsNewStore, finishedFirstRun: Boolean, release: WhatsNewRelease? = WhatsNewRelease.current) {
    var shown by remember { mutableStateOf<WhatsNewRelease?>(null) }
    LaunchedEffect(release?.id) {
        when (WhatsNewPolicy.decide(release?.id, store.lastSeen(), finishedFirstRun)) {
            WhatsNewPolicy.Decision.Show -> {
                // Let the landing screen settle so the sheet does not race the first layout.
                delay(SETTLE_MILLIS)
                release?.let { store.record(it.id) }
                shown = release
            }
            WhatsNewPolicy.Decision.RecordWithoutShowing -> release?.let { store.record(it.id) }
            WhatsNewPolicy.Decision.Nothing -> Unit
        }
    }
    shown?.let { WhatsNewSheet(it, onDismiss = { shown = null }) }
}

private const val SETTLE_MILLIS = 1_000L

@Composable
internal fun WhatsNewSheet(release: WhatsNewRelease, onDismiss: () -> Unit) {
    PeeringSheet(onDismiss = onDismiss, title = stringResource(R.string.whatsnew_title), scrollable = true) {
        Column(Modifier.padding(horizontal = 18.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            release.items.forEach { item ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Icon(item.icon, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(28.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(stringResource(item.title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
                        Text(stringResource(item.detail), style = PeeringText.footnote, color = PeeringColors.muted)
                    }
                }
            }
            PrimaryButton(stringResource(R.string.whatsnew_done), onDismiss, Modifier.fillMaxWidth().padding(top = 6.dp))
        }
    }
}
