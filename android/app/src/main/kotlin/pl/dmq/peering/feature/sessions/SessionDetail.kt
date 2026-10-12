package pl.dmq.peering.feature.sessions

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import pl.dmq.peering.ui.kit.relativeTime
import pl.dmq.peering.ui.kit.englishDateTime
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** One recorded session: the connection card and the log card, under the computer's name with a way back. */
@Composable
fun SessionDetail(record: SessionRecord, nowMillis: Long, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 18.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(AppIcons.back, contentDescription = stringResource(R.string.sessions_detail_back), tint = PeeringColors.ink)
            }
            Text(record.hostName, style = PeeringText.headline, color = PeeringColors.ink, maxLines = 1)
        }
        ControlsCard(stringResource(R.string.sessions_detail_connection)) {
            DetailRow(stringResource(R.string.sessions_detail_computer), record.hostName)
            ControlsDivider()
            DetailRow(stringResource(R.string.sessions_detail_path), stringResource(record.path.nameRes()))
            ControlsDivider()
            DetailRow(
                stringResource(R.string.sessions_detail_started),
                englishDateTime(record.startedAt),
            )
            ControlsDivider()
            DetailRow(stringResource(R.string.sessions_detail_duration), durationLabel(record.durationSeconds(nowMillis)))
            record.reason?.let {
                ControlsDivider()
                DetailRow(stringResource(R.string.sessions_detail_ended), stringResource(it.labelRes()))
            }
        }
        ControlsCard(stringResource(R.string.sessions_detail_log)) {
            Text(stringResource(R.string.sessions_detail_log_empty), style = PeeringText.subheadline, color = PeeringColors.muted)
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Text(label, style = PeeringText.subheadline, color = PeeringColors.muted)
        Text(value, style = PeeringText.subheadline, color = PeeringColors.ink, textAlign = TextAlign.End, modifier = Modifier.weight(1f).padding(start = 12.dp))
    }
}

@StringRes
internal fun SessionRecord.Path.nameRes(): Int = when (this) {
    SessionRecord.Path.LAN -> R.string.overlay_path_lan
    SessionRecord.Path.RELAY -> R.string.overlay_path_relay
    SessionRecord.Path.DIRECT -> R.string.overlay_path_direct
}

@StringRes
internal fun SessionRecord.EndReason.labelRes(): Int = when (this) {
    SessionRecord.EndReason.USER_ENDED -> R.string.sessions_ended_user
    SessionRecord.EndReason.HOST_STOPPED -> R.string.sessions_ended_host
    SessionRecord.EndReason.CONNECTION_LOST -> R.string.sessions_ended_lost
    SessionRecord.EndReason.FAILED -> R.string.sessions_ended_failed
}

internal fun relativeTime(resources: android.content.res.Resources, thenMillis: Long, nowMillis: Long): String =
    resources.relativeTime(thenMillis, nowMillis)
