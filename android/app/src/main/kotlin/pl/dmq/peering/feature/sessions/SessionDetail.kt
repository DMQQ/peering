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
import android.content.ClipboardManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import pl.dmq.peering.feature.remote.copyText
import pl.dmq.peering.ui.kit.relativeTime
import pl.dmq.peering.ui.kit.localizedDateTime
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.BuildConfig
import pl.dmq.peering.R
import pl.dmq.peering.feature.files.fileSizeLabel
import androidx.compose.ui.text.font.FontFamily
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
    val logText = sessionLogText(record, BuildConfig.VERSION_NAME, localizedDateTime(record.startedAt), nowMillis)
    Column(modifier.verticalScroll(rememberScrollState()).padding(horizontal = 18.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(AppIcons.back, contentDescription = stringResource(R.string.sessions_detail_back), tint = PeeringColors.ink)
            }
            Text(record.hostName, style = PeeringText.headline, color = PeeringColors.ink, maxLines = 1, modifier = Modifier.weight(1f))
            CopyLogButton(logText)
        }
        SessionConnectionCard(record, nowMillis)
        SessionLogCard(record)
    }
}

@Composable
private fun SessionConnectionCard(record: SessionRecord, nowMillis: Long) {
    ControlsCard(stringResource(R.string.sessions_detail_connection)) {
        DetailRow(stringResource(R.string.sessions_detail_computer), record.hostName)
        ControlsDivider()
        DetailRow(stringResource(R.string.sessions_detail_path), stringResource(record.path.nameRes()))
        ControlsDivider()
        DetailRow(
            stringResource(R.string.sessions_detail_started),
            localizedDateTime(record.startedAt),
        )
        ControlsDivider()
        DetailRow(stringResource(R.string.sessions_detail_duration), durationLabel(record.durationSeconds(nowMillis)))
        record.reason?.let {
            ControlsDivider()
            DetailRow(stringResource(R.string.sessions_detail_ended), stringResource(it.labelRes()))
        }
        ControlsDivider()
        DetailRow(stringResource(R.string.sessions_detail_received), fileSizeLabel(record.bytesReceived))
        ControlsDivider()
        DetailRow(stringResource(R.string.sessions_detail_sent), fileSizeLabel(record.bytesSent))
    }
}

@Composable
private fun SessionLogCard(record: SessionRecord) {
    ControlsCard(stringResource(R.string.sessions_detail_log)) {
        if (record.logs.isEmpty()) {
            Text(stringResource(R.string.sessions_detail_log_empty), style = PeeringText.subheadline, color = PeeringColors.muted)
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                record.logs.forEach { entry ->
                    Text(entry, style = PeeringText.caption.copy(fontFamily = FontFamily.Monospace), color = PeeringColors.muted)
                }
            }
        }
    }
}

@Composable
private fun CopyLogButton(text: String) {
    val clipboard = LocalContext.current.getSystemService(ClipboardManager::class.java)
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(COPIED_SHOWN_MILLIS)
            copied = false
        }
    }
    if (copied) {
        Text(stringResource(R.string.sessions_detail_copied), style = PeeringText.captionSemibold, color = PeeringColors.accent)
    }
    IconButton(onClick = {
        clipboard.copyText("Peering session log", text)
        copied = true
    }) {
        Icon(
            if (copied) AppIcons.check else AppIcons.copy,
            contentDescription = stringResource(R.string.sessions_detail_copy),
            tint = PeeringColors.ink,
        )
    }
}

private const val COPIED_SHOWN_MILLIS = 2_000L

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
