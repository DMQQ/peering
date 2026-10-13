package pl.dmq.peering.feature.remote.dictation

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.remote.CompactKey
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** What the keyboard bar shows while listening: a live waveform, the words as they are recognised, and the two ways out. */
@Composable
internal fun DictationOverlay(dictation: VoiceDictation, modifier: Modifier = Modifier) {
    val listening = dictation.state == VoiceDictation.State.Listening
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        CompactKey(AppIcons.close, stringResource(R.string.dictation_cancel), dictation::cancel, large = true)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            DictationWaveform(dictation.levels.bars, listening, Modifier.fillMaxWidth().height(WAVEFORM_HEIGHT))
            Text(
                text = caption(dictation),
                style = PeeringText.footnote,
                color = if (dictation.transcript.isEmpty()) PeeringColors.muted else PeeringColors.ink,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth(),
            )
        }
        CompactKey(AppIcons.check, stringResource(R.string.dictation_done), dictation::finish, filled = true, large = true)
    }
}

@Composable
private fun caption(dictation: VoiceDictation): String = when {
    dictation.transcript.isNotEmpty() -> dictation.transcript.takeLast(CAPTION_TAIL)
    dictation.state == VoiceDictation.State.Finishing -> ""
    else -> stringResource(R.string.dictation_listening)
}

/** Bars that rise with the voice, newest on the right. Quiet is a row of dots rather than nothing, so it never looks broken. */
@Composable
private fun DictationWaveform(levels: List<Float>, live: Boolean, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val pitch = size.width / levels.size
        val width = maxOf(2.dp.toPx(), pitch * BAR_FILL)
        levels.forEachIndexed { index, level ->
            val height = maxOf(width, level * size.height)
            val recency = RECENCY_FLOOR + (1f - RECENCY_FLOOR) * (index + 1) / levels.size
            drawRoundRect(
                color = PeeringColors.ink.copy(alpha = if (live) recency else IDLE_ALPHA),
                topLeft = Offset(index * pitch + (pitch - width) / 2, (size.height - height) / 2),
                size = Size(width, height),
                cornerRadius = CornerRadius(width / 2),
            )
        }
    }
}

/** Shown in the bar's place when listening cannot start. */
@Composable
internal fun DictationNotice(denied: Boolean, dismiss: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(SessionIcons.microphoneOff, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
        Text(
            text = stringResource(if (denied) R.string.dictation_denied else R.string.dictation_unavailable),
            style = PeeringText.footnote,
            color = PeeringColors.ink,
            modifier = Modifier.weight(1f),
        )
        if (denied) {
            Text(
                text = stringResource(R.string.dictation_settings),
                style = PeeringText.footnote,
                color = PeeringColors.ink,
                modifier = Modifier.tappable({ context.openAppSettings(); dismiss() }),
            )
        }
        CompactKey(AppIcons.close, stringResource(R.string.dictation_close), dismiss)
    }
}

/** The key that starts listening. */
@Composable
internal fun DictationKey(onClick: () -> Unit) {
    CompactKey(SessionIcons.microphone, stringResource(R.string.dictation_start), onClick)
}

private fun Context.openAppSettings() {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
    startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

private val WAVEFORM_HEIGHT = 26.dp
private const val CAPTION_TAIL = 120
private const val BAR_FILL = 0.55f
private const val RECENCY_FLOOR = 0.35f
private const val IDLE_ALPHA = 0.3f
